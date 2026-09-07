import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusItemController!
    private var session: SessionStore?
    private var client: FirestoreClient?
    private var orderService: OrderService?
    private var listener: ShopListener?
    private var queue: QueueService?
    private var orderWindow: OrderWindowController?
    private var loginServer: LoginServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController()
        Task { @MainActor in await self.bootstrap() }
    }

    @MainActor
    private func bootstrap() async {
        let sessionStore: SessionStore
        do {
            sessionStore = try SessionStore()
        } catch {
            status.showSetupError(error.localizedDescription)
            return
        }
        session = sessionStore

        // Config comes from the CLI's env vars, falling back to ~/.coffee.json
        // for launches outside a shell (Finder, brew services).
        // Config resolution order: env vars (CLI shell) → ~/.coffee.json →
        // embedded public defaults, so the app self-bootstraps with no CLI.
        let env = ProcessInfo.processInfo.environment
        var projectID = env["COFFEE_PROJECT_ID"] ?? ""
        var apiKey = env["COFFEE_API_KEY"] ?? ""
        if projectID.isEmpty { projectID = await sessionStore.value("project_id") ?? "" }
        if apiKey.isEmpty { apiKey = await sessionStore.value("api_key") ?? "" }
        if projectID.isEmpty { projectID = AppConfig.defaultProjectID }
        if apiKey.isEmpty { apiKey = AppConfig.defaultAPIKey }

        let config = AppConfig(projectID: projectID, apiKey: apiKey)
        if await sessionStore.hasSession {
            await startServices(config: config, sessionStore: sessionStore)
        } else {
            await beginLogin(config: config, sessionStore: sessionStore)
        }
    }

    /// No tokens in ~/.coffee.json — serve the local sign-in page, open it in
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
        status.onRefresh = { [weak self] in self?.queue?.refreshNow() }

        let queue = QueueService(client: client)
        queue.onUpdate = { [weak self] queuing, ordersToday, orders in
            self?.status.setQueue(queuing: queuing, ordersToday: ordersToday, orders: orders)
        }
        queue.onStatuses = { [weak self] statuses in
            guard let self, let orderService = self.orderService else { return }
            // Flash the icon when an order this app placed is completed.
            if orderService.notePendingStatuses(statuses) {
                self.status.startFlashing()
            }
        }
        queue.onError = { [weak self] message in
            self?.status.setRefreshError(message)
        }
        queue.start()
        self.queue = queue

        let listener = ShopListener(config: config, session: sessionStore)
        listener.onState = { [weak self] state in
            self?.shopStateChanged(state)
        }
        listener.start()
        self.listener = listener

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
        queue?.setPolling(state == .open)
        if state == .open && previous != .open {
            if previous == .closed {
                playOpenSound()
                // The rush is right after opening: poll fast for the first 5
                // minutes, then settle back to once a minute.
                queue?.beginBurst(seconds: 300)
            }
            queue?.refreshNow()
        }
    }

    private func playOpenSound() {
        // Same fanfare as the CLI's WaitForShopOpen.
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
                self?.queue?.refreshNow()
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
                let (position, _) = try await orderService.place(
                    drinkID: order.drinkID,
                    drinkName: order.drinkName,
                    options: options,
                    shots: order.shots
                )
                reloadRecentOrders()
                queue?.refreshNow()
                let suffix = position.map { " You're number \($0) in the queue." } ?? ""
                alert(title: "Order placed", text: "\(order.summary) ordered.\(suffix)")
            } catch {
                alert(title: "Order failed", text: error.localizedDescription)
            }
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

    @MainActor
    private func alert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
