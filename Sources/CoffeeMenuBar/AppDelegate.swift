import AppKit

/// A notification to post, with the Notifications-menu toggle that governs it.
typealias Announcement = (kind: NotificationKind, title: String, body: String)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusItemController!
    private var notifier: Notifier!
    private var session: SessionStore?
    private var client: FirestoreClient?
    private var orderService: OrderService?
    private var listener: ShopListener?
    private var orders: OrdersListener?
    private var orderWindow: OrderWindowController?
    private var loginServer: LoginServer?
    private var lastOrders: LastOrdersReminder?
    private let statusTracker = OrderStatusTracker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController()
        notifier = Notifier()
        Task { @MainActor in await self.bootstrap() }
    }

    @MainActor
    private func bootstrap() async {
        let sessionStore = SessionStore()
        session = sessionStore

        // Config: stored defaults override the embedded public defaults, so
        // the app self-bootstraps with no other setup.
        var projectID = await sessionStore.value("project_id") ?? ""
        var apiKey = await sessionStore.value("api_key") ?? ""
        if projectID.isEmpty { projectID = AppConfig.defaultProjectID }
        if apiKey.isEmpty { apiKey = AppConfig.defaultAPIKey }

        let config = AppConfig(projectID: projectID, apiKey: apiKey)
        if await sessionStore.hasSession {
            await startServices(config: config, sessionStore: sessionStore)
        } else {
            await beginLogin(config: config, sessionStore: sessionStore)
        }
    }

    /// No stored tokens — serve the local sign-in page, open it in
    /// the browser, and start the services once credentials arrive.
    @MainActor
    private func beginLogin(config: AppConfig, sessionStore: SessionStore) async {
        let hint = await sessionStore.value("email")
        let server = LoginServer(config: config, loginHint: hint)
        loginServer = server
        server.onCredentials = { [weak self] creds in
            Task { @MainActor in
                guard let self, self.loginServer != nil else { return }
                self.loginServer?.stop()
                self.loginServer = nil
                await sessionStore.applyLogin(creds)
                self.status.clearSignIn()
                log("signed in as \(creds.email) (\(creds.uid))")
                await self.startServices(config: config, sessionStore: sessionStore)
            }
        }
        do {
            let url = try await server.start()
            status.showSignIn { NSWorkspace.shared.open(url) }
            NSWorkspace.shared.open(url)
            log("no session — opened sign-in page \(url)")
        } catch {
            status.showSetupError("Could not start sign-in: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func startServices(config: AppConfig, sessionStore: SessionStore) async {
        let client = FirestoreClient(config: config, session: sessionStore)
        self.client = client
        self.orderService = OrderService(client: client, session: sessionStore, config: config)

        status.recentOrders = await sessionStore.recentOrders()
        status.onNewOrder = { [weak self] in self?.showOrderWindow() }
        status.onReorder = { [weak self] order in self?.reorder(order) }
        status.onForget = { [weak self] order in
            guard let self, let session = self.session else { return }
            Task { @MainActor in
                await session.forgetRecentOrder(order)
                self.status.recentOrders = await session.recentOrders()
            }
        }
        status.onCancel = { [weak self] order in self?.cancel(order) }
        status.heldOrders = { [weak self] in self?.orderService?.heldOrders() ?? [] }
        status.onCancelDeferred = { [weak self] order in self?.cancelDeferred(order) }
        let orders = OrdersListener(config: config, session: sessionStore, uid: await sessionStore.info().uid)
        orders.onUpdate = { [weak self] queuing, ordersToday, queued in
            self?.status.setQueue(queuing: queuing, ordersToday: ordersToday, orders: queued)
        }
        orders.onOrders = { [weak self] orders in
            guard let self else { return }
            let changes = self.statusTracker.note(orders)
            // A ready order also flashes the icon until the menu is opened.
            if changes.contains(where: { $0.status == "completed" }) {
                self.status.startFlashing()
            }
            for message in Self.notifications(for: changes) {
                self.notify(message.kind, title: message.title, text: message.body)
            }
        }
        orders.start()
        self.orders = orders

        let listener = ShopListener(config: config, session: sessionStore)
        listener.onState = { [weak self] state in
            self?.shopStateChanged(state)
        }
        listener.start()
        self.listener = listener

        let lastOrders = LastOrdersReminder(
            shopIsOpen: { [weak self] in self?.status.shop == .open },
            notify: { [weak self] in
                self?.notify(.lastOrders, title: LastOrdersReminder.message.title, text: LastOrdersReminder.message.body)
            }
        )
        lastOrders.start()
        self.lastOrders = lastOrders

        log("coffee menu bar started (project \(config.projectID))")
    }

    @MainActor
    private func shopStateChanged(_ state: ShopState) {
        if state != status.shop {
            log("shop state: \(state)")
        }
        let previous = status.shop
        status.setShop(state)
        orderWindow?.shopStateChanged(state)
        orderService?.setShopOpen(state == .open)
        if let message = Self.shopNotification(from: previous, to: state) {
            notify(message.kind, title: message.title, text: message.body)
        }
        if state == .open && previous != .open {
            if previous == .closed {
                playOpenSound()
            }
            // Re-anchor the orders query at today's midnight in case the app
            // sat connected across the day boundary.
            orders?.refreshNow()
            flushDeferredOrders()
        }
    }

    /// Places any orders that "Only Order When Open" held back while the shop
    /// was closed.
    @MainActor
    private func flushDeferredOrders() {
        guard let orderService else { return }
        let held = orderService.takeDeferred()
        guard !held.isEmpty else { return }
        Task { @MainActor in
            for order in held {
                do {
                    let outcome = try await orderService.place(
                        drinkID: order.drinkID,
                        drinkName: order.drinkName,
                        options: order.options,
                        shots: order.shots
                    )
                    if case .placed(let position, _) = outcome {
                        reloadRecentOrders()
                        let suffix = position.map { " You're number \($0) in the queue." } ?? ""
                        notify(.orderPlaced, title: "Order placed", text: "\(order.drinkName) ordered now the shop is open.\(suffix)")
                    }
                } catch {
                    notify(.orderFailed, title: "Order failed", text: "\(order.drinkName): \(error.localizedDescription)")
                }
            }
        }
    }

    private func playOpenSound() {
        guard Settings.playSounds else { return }
        if let sound = NSSound(named: "Funk") {
            sound.play()
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            process.arguments = ["/System/Library/Sounds/Funk.aiff"]
            try? process.run()
        }
    }

    @MainActor
    private func showOrderWindow() {
        guard let client, let orderService else { return }
        if orderWindow == nil {
            let controller = OrderWindowController(client: client, orderService: orderService)
            controller.onPlaced = { [weak self] _ in
                self?.reloadRecentOrders()
            }
            orderWindow = controller
        }
        orderWindow?.shopStateChanged(status.shop)
        orderWindow?.show()
    }

    @MainActor
    private func reorder(_ order: LastOrder) {
        guard let orderService else { return }
        Task { @MainActor in
            do {
                let options = order.options.map {
                    SelectedOption(collection: $0.collection, id: $0.id, name: $0.name, count: $0.count ?? 1)
                }
                let outcome = try await orderService.place(
                    drinkID: order.drinkID,
                    drinkName: order.drinkName,
                    options: options,
                    shots: order.shots
                )
                switch outcome {
                case .placed(let position, _):
                    reloadRecentOrders()
                    let suffix = position.map { " You're number \($0) in the queue." } ?? ""
                    notify(.orderPlaced, title: "Order placed", text: "\(order.summary) ordered.\(suffix)")
                case .deferredUntilOpen:
                    notify(.orderPlaced, title: "Order held", text: "\(order.summary) will be ordered when the shop opens. You can cancel it from the menu until then.")
                }
            } catch {
                notify(.orderFailed, title: "Order failed", text: error.localizedDescription)
            }
        }
    }

    /// Cancels one of the user's queued orders. The orders listener sees the
    /// status change and removes it from the menu and the icon's position;
    /// the confirmation here stands in for the tracker's announcement.
    @MainActor
    private func cancel(_ order: Order) {
        guard let orderService else { return }
        statusTracker.expectCancellation(of: order.id)
        Task { @MainActor in
            do {
                try await orderService.cancel(orderID: order.id)
                notify(.orderCancelledByYou, title: "Order cancelled", text: "\(order.drinkName) has been cancelled.")
            } catch {
                statusTracker.forgetExpectedCancellation(of: order.id)
                notify(.orderFailed, title: "Cancel failed", text: "\(order.drinkName): \(error.localizedDescription)")
            }
        }
    }

    /// Drops an order that "Only Order When Open" was holding back. If the
    /// shop opened in the meantime the flush has already placed it, and the
    /// usual queue Cancel takes over once the listener sees the document.
    @MainActor
    private func cancelDeferred(_ order: DeferredOrder) {
        guard let orderService else { return }
        if orderService.removeDeferred(id: order.id) {
            notify(.orderCancelledByYou, title: "Order cancelled", text: "\(order.drinkName) will not be ordered.")
        } else {
            notify(.orderPlaced, title: "Already ordered", text: "\(order.drinkName) was sent when the shop opened. You can still cancel it from the menu while it's queuing.")
        }
    }

    /// Re-reads the recent-orders list after OrderService saves a new entry, so
    /// the menu reflects the latest ordering.
    @MainActor
    private func reloadRecentOrders() {
        guard let session else { return }
        Task { @MainActor in
            status.recentOrders = await session.recentOrders()
        }
    }

    /// The notification for a shop state change. Only a real opening or
    /// closing counts: startup and listener reconnects pass through .unknown
    /// and re-deliver the current state, and neither is news.
    static func shopNotification(from previous: ShopState, to state: ShopState) -> Announcement? {
        switch (previous, state) {
        case (.closed, .open):
            return (.shopOpens, "Shop open", "The coffee shop is now open.")
        case (.open, .closed):
            return (.shopCloses, "Shop closed", "The coffee shop is now closed.")
        default:
            return nil
        }
    }

    /// The notifications for your orders changing status. Orders completed in
    /// the same update share one "ready" notification.
    static func notifications(for changes: [OrderStatusChange]) -> [Announcement] {
        var messages: [Announcement] = []
        for change in changes {
            switch change.status {
            case "being-prepared":
                messages.append((.orderBeingPrepared, "Order being prepared", "Your \(change.drinkName) is being prepared."))
            case "cancelled":
                messages.append((.orderCancelledByShop, "Order cancelled", "Your \(change.drinkName) was cancelled."))
            default:
                break
            }
        }
        let ready = changes.filter { $0.status == "completed" }.map(\.drinkName)
        if !ready.isEmpty {
            messages.append((.orderReady, "Order ready", readyText(ready)))
        }
        return messages
    }

    /// "Your Latte is ready." / "Your Latte and Flat White are ready."
    static func readyText(_ drinks: [String]) -> String {
        guard let last = drinks.last else { return "Your order is ready." }
        if drinks.count == 1 {
            return "Your \(last) is ready."
        }
        let list = drinks.dropLast().joined(separator: ", ") + " and " + last
        return "Your \(list) are ready."
    }

    /// Posts the notification unless its toggle in the Notifications menu is
    /// off.
    private func notify(_ kind: NotificationKind, title: String, text: String) {
        guard Settings.notifies(kind) else { return }
        notifier.notify(title: title, body: text)
    }
}
