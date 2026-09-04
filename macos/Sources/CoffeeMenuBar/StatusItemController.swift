import AppKit

/// The menu bar item: a template coffee cup (crossed out while the shop is
/// closed), the queue size as its title, and the dropdown menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var flashTimer: Timer?
    private var flashDimmed = false

    private(set) var shop: ShopState = .unknown
    private var queuing: Int?
    private var ordersToday: Int?
    private var setupError: String?
    private var lastRefreshError: String?

    var recentOrders: [LastOrder] = []
    private var queueOrders: [QueuedOrder] = []

    var onNewOrder: (() -> Void)?
    var onReorder: ((LastOrder) -> Void)?
    var onRefresh: (() -> Void)?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        render()
    }

    func setShop(_ state: ShopState) {
        shop = state
        render()
    }

    func setQueue(queuing: Int, ordersToday: Int, orders: [QueuedOrder]) {
        self.queuing = queuing
        self.ordersToday = ordersToday
        self.queueOrders = orders
        lastRefreshError = nil
        render()
    }

    func setRefreshError(_ message: String) {
        lastRefreshError = message
    }

    func showSetupError(_ message: String) {
        setupError = message
        render()
    }

    private func render() {
        guard let button = item.button else { return }
        button.image = Self.icon(for: shop)
        button.imagePosition = .imageLeft
        button.title = queuing.map { " \($0)" } ?? ""
        switch shop {
        case .open: button.toolTip = "Coffee shop is open"
        case .closed: button.toolTip = "Coffee shop is closed"
        case .unknown: button.toolTip = setupError ?? "Coffee shop status unknown"
        }
    }

    private static func icon(for state: ShopState) -> NSImage {
        switch state {
        case .open: return cup(filled: true)
        case .closed: return slashedCup()
        case .unknown: return cup(filled: false) // outline cup for "unknown"
        }
    }

    /// The cup as a standard template image, so it renders like every other
    /// menu bar icon (light/dark menu bars, highlighted state).
    private static func cup(filled: Bool) -> NSImage {
        let name = filled ? "cup.and.saucer.fill" : "cup.and.saucer"
        if let base = NSImage(systemSymbolName: name, accessibilityDescription: "Coffee") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            if let image = base.withSymbolConfiguration(config) {
                image.isTemplate = true
                return image
            }
        }
        // Fallback if the symbol is unavailable: a plain dot.
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// There is no "cup.and.saucer.slash" symbol, so composite one: the cup
    /// with a diagonal line through it, knocking out a slightly wider band
    /// first so the slash has a gap around it like Apple's .slash symbols.
    /// Only the alpha channel matters for a template image, so it stays
    /// monochrome.
    private static func slashedCup() -> NSImage {
        let base = cup(filled: true)
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 2, y: rect.maxY - 1))
            slash.line(to: NSPoint(x: rect.maxX - 2, y: rect.minY + 1))
            slash.lineCapStyle = .round
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            NSColor.black.setStroke()
            ctx.setBlendMode(.destinationOut)
            slash.lineWidth = 3.5
            slash.stroke()
            ctx.setBlendMode(.normal)
            slash.lineWidth = 1.5
            slash.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Completion flash

    /// Flashes the status item until the user opens the menu, to announce
    /// that an order they placed has been completed.
    func startFlashing() {
        guard flashTimer == nil else { return } // already flashing; don't stack timers
        flashTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(flashTick), userInfo: nil, repeats: true)
        flashTick()
    }

    @objc private func flashTick() {
        flashDimmed.toggle()
        item.button?.alphaValue = flashDimmed ? 0.25 : 1
    }

    private func stopFlashing() {
        flashTimer?.invalidate()
        flashTimer = nil
        flashDimmed = false
        item.button?.alphaValue = 1
    }

    // MARK: - Menu

    /// Opening the menu is the "seen it" signal that ends a completion flash.
    func menuWillOpen(_ menu: NSMenu) {
        stopFlashing()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let setupError {
            let header = disabledItem("Coffee — setup needed")
            menu.addItem(header)
            let detail = disabledItem(setupError)
            detail.toolTip = setupError
            menu.addItem(detail)
            menu.addItem(.separator())
            menu.addItem(quitItem())
            return
        }

        menu.addItem(shopLine())

        if let lastRefreshError {
            let err = disabledItem("Refresh failed")
            err.toolTip = lastRefreshError
            menu.addItem(err)
        }

        menu.addItem(.separator())

        for (index, order) in recentOrders.enumerated() {
            // ⌘O always reorders the most recent order; older ones are click-only.
            let reorder = NSMenuItem(title: "Reorder \(order.summary)", action: #selector(reorderClicked(_:)), keyEquivalent: index == 0 ? "o" : "")
            reorder.target = self
            reorder.toolTip = order.optionsSummary
            reorder.representedObject = order
            menu.addItem(reorder)
        }

        if !recentOrders.isEmpty {
            menu.addItem(.separator())
        }

        let newOrder = NSMenuItem(title: "New Order…", action: #selector(newOrderClicked), keyEquivalent: "n")
        newOrder.target = self
        menu.addItem(newOrder)

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshClicked), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(quitItem())

        if !queueOrders.isEmpty {
            menu.addItem(.separator())
            for (index, order) in queueOrders.enumerated() {
                menu.addItem(disabledItem("\(index + 1). \(order.userName) — \(order.drinkName)"))
            }
        }
    }

    private func shopLine() -> NSMenuItem {
        let (text, color): (String, NSColor) = {
            switch shop {
            case .open: return ("Shop is open", .systemGreen)
            case .closed: return ("Shop is closed", .systemRed)
            case .unknown: return ("Shop status unknown", .systemGray)
            }
        }()
        let item = disabledItem("")
        var line = text
        if let ordersToday {
            line += " · \(ordersToday) orders today"
        }
        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
        title.append(NSAttributedString(string: line, attributes: [.foregroundColor: NSColor.labelColor]))
        item.attributedTitle = title
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func quitItem() -> NSMenuItem {
        // A custom action rather than terminate(_:) — macOS 26 auto-adds an
        // icon to standard-selector items, misaligning it with the rest.
        let quit = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        return quit
    }

    @objc private func quitClicked() { NSApp.terminate(nil) }
    @objc private func newOrderClicked() { onNewOrder?() }
    @objc private func refreshClicked() { onRefresh?() }

    @objc private func reorderClicked(_ sender: NSMenuItem) {
        guard let order = sender.representedObject as? LastOrder else { return }
        onReorder?(order)
    }
}
