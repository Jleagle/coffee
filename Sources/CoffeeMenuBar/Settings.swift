import Foundation

/// App-local preferences behind the Settings and Notifications submenus,
/// persisted in UserDefaults.
enum Settings {
    /// Show the queue entries at the bottom of the dropdown.
    static var showQueue: Bool {
        get { UserDefaults.standard.object(forKey: "showQueue") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showQueue") }
    }

    /// Show the queue size next to the menu bar icon.
    static var showQueueSize: Bool {
        get { UserDefaults.standard.object(forKey: "showQueueSize") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showQueueSize") }
    }

    /// Hold orders placed while the shop is closed and send them automatically
    /// as soon as it opens.
    static var onlyOrderWhenOpen: Bool {
        get { UserDefaults.standard.object(forKey: "onlyOrderWhenOpen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "onlyOrderWhenOpen") }
    }

    /// Play a sound with every notification and the shop-open fanfare. Off by
    /// default.
    static var playSounds: Bool {
        get { UserDefaults.standard.object(forKey: "playSounds") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "playSounds") }
    }
}

/// The events that post a notification, each with its own toggle in the
/// Notifications submenu. The raw value is the UserDefaults key.
enum NotificationKind: String, CaseIterable {
    case shopOpens = "notifyShopOpens"
    case shopCloses = "notifyShopCloses"
    case lastOrders = "notifyLastOrders"
    case orderPlaced = "notifyOrderPlaced"
    case orderBeingPrepared = "notifyOrderBeingPrepared"
    case orderReady = "notifyOrderReady"
    case orderCancelledByShop = "notifyOrderCancelledByShop"
    case orderCancelledByYou = "notifyOrderCancelledByYou"
    case orderFailed = "notifyOrderFailed"

    /// The menu item's title.
    var title: String {
        switch self {
        case .shopOpens: return "Shop Opens"
        case .shopCloses: return "Shop Closes"
        case .lastOrders: return "Last Orders"
        case .orderPlaced: return "Order Placed"
        case .orderBeingPrepared: return "Order Being Prepared"
        case .orderReady: return "Order Ready"
        case .orderCancelledByShop: return "Order Cancelled by the Shop"
        case .orderCancelledByYou: return "Order Cancelled by You"
        case .orderFailed: return "Order Failed"
        }
    }

    /// The menu item's tooltip: what the toggle covers.
    var toolTip: String {
        switch self {
        case .shopOpens: return "When the coffee shop opens"
        case .shopCloses: return "When the coffee shop closes"
        case .lastOrders: return "Ten minutes before the shop closes"
        case .orderPlaced: return "When a reorder from this menu is placed or held until the shop opens"
        case .orderBeingPrepared: return "When the barista starts on your order"
        case .orderReady: return "When your order is ready to collect (the icon still flashes)"
        case .orderCancelledByShop: return "When the shop cancels your order"
        case .orderCancelledByYou: return "Confirmation after you cancel an order from this menu"
        case .orderFailed: return "When placing or cancelling an order fails"
        }
    }
}

extension Settings {
    /// Whether notifications of this kind are posted. All on by default.
    static func notifies(_ kind: NotificationKind) -> Bool {
        UserDefaults.standard.object(forKey: kind.rawValue) as? Bool ?? true
    }

    static func setNotifies(_ kind: NotificationKind, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: kind.rawValue)
    }
}
