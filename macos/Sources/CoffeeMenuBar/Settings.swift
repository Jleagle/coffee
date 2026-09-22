import Foundation

/// App-local preferences behind the Settings submenu, persisted in
/// UserDefaults.
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
