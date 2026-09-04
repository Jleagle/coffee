import AppKit

/// The menu bar item: a red/green coffee cup for shop status, the queue size
/// as its title, and the dropdown menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()

    private(set) var shop: ShopState = .unknown
    private var queuing: Int?
    private var ordersToday: Int?
    private var setupError: String?
    private var lastRefreshError: String?

    var lastOrder: LastOrder?

    var onNewOrder: (() -> Void)?
    var onReorder: (() -> Void)?
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

    func setQueue(queuing: Int, ordersToday: Int) {
        self.queuing = queuing
        self.ordersToday = ordersToday
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
        button.image = Self.cup(color: Self.color(for: shop))
        button.imagePosition = .imageLeft
        button.title = queuing.map { " \($0)" } ?? ""
        switch shop {
        case .open: button.toolTip = "Coffee shop is open"
        case .closed: button.toolTip = "Coffee shop is closed"
        case .unknown: button.toolTip = setupError ?? "Coffee shop status unknown"
        }
    }

    private static func color(for state: ShopState) -> NSColor {
        switch state {
        case .open: return .systemGreen
        case .closed: return .systemRed
        case .unknown: return .systemGray
        }
    }

    private static func cup(color: NSColor) -> NSImage {
        if let base = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Coffee") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [color]))
            if let image = base.withSymbolConfiguration(config) {
                image.isTemplate = false
                return image
            }
        }
        // Fallback if the symbol is unavailable: a plain coloured dot.
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Menu

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

        if let queuing, let ordersToday {
            let noun = queuing == 1 ? "person" : "people"
            menu.addItem(disabledItem("\(queuing) \(noun) in queue · \(ordersToday) orders today"))
        }
        if let lastRefreshError {
            let err = disabledItem("Refresh failed")
            err.toolTip = lastRefreshError
            menu.addItem(err)
        }

        menu.addItem(.separator())

        if let lastOrder {
            let reorder = NSMenuItem(title: "Reorder \(lastOrder.summary)", action: #selector(reorderClicked), keyEquivalent: "r")
            reorder.target = self
            reorder.toolTip = lastOrder.optionsSummary
            reorder.isEnabled = shop == .open
            if shop != .open {
                reorder.title += shop == .closed ? " (shop closed)" : " (status unknown)"
            }
            menu.addItem(reorder)
        }

        let newOrder = NSMenuItem(title: "New Order…", action: #selector(newOrderClicked), keyEquivalent: "n")
        newOrder.target = self
        menu.addItem(newOrder)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshClicked), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        menu.addItem(quitItem())
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
        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
        title.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor]))
        item.attributedTitle = title
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func quitItem() -> NSMenuItem {
        let quit = NSMenuItem(title: "Quit Coffee", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return quit
    }

    @objc private func newOrderClicked() { onNewOrder?() }
    @objc private func reorderClicked() { onReorder?() }
    @objc private func refreshClicked() { onRefresh?() }
}
