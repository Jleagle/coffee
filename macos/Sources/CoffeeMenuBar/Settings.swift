import Foundation

/// App-local preferences behind the Settings submenu, persisted in
/// UserDefaults. All default to on until toggled.
enum Settings {
    /// Show the queue entries at the bottom of the dropdown.
    static var showQueue: Bool {
        get { UserDefaults.standard.object(forKey: "showQueue") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showQueue") }
    }

    /// Hold orders placed while the shop is closed and send them automatically
    /// as soon as it opens.
    static var onlyOrderWhenOpen: Bool {
        get { UserDefaults.standard.object(forKey: "onlyOrderWhenOpen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "onlyOrderWhenOpen") }
    }
}
