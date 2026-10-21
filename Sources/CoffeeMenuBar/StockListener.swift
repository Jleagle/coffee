import AppKit

struct DrinkStock: Sendable, Equatable {
    let name: String
    let inStock: Bool
}

/// Live view of which drinks are out of stock, via a Firestore query listen on
/// the drinks collection. The shop marks a drink out of stock by setting its
/// `enabled` field to false; a drink without the field is in stock, matching
/// the web app.
final class StockListener: @unchecked Sendable {
    private let inner: FirestoreListener
    private let lock = NSLock()
    private var drinks: [String: DrinkStock] = [:]
    /// False while a (re)connect is re-delivering the collection, so a
    /// half-loaded mirror is never reported.
    private var current = false

    /// Called on the main queue with every drink, keyed by ID.
    var onUpdate: (([String: DrinkStock]) -> Void)?

    init(config: AppConfig, session: SessionStore) {
        inner = FirestoreListener(config: config, session: session) {
            [
                "query": [
                    "parent": "\(config.database)/documents",
                    "structuredQuery": ["from": [["collectionId": "drinks"]]],
                ] as [String: Any],
                "targetId": 1,
            ]
        }
        inner.onReset = { [weak self] in self?.reset() }
        inner.onMessage = { [weak self] msg in self?.handle(msg) }
    }

    func start() { inner.start() }
    func stop() { inner.stop() }

    static func outOfStock(_ drinks: [String: DrinkStock]) -> Set<String> {
        Set(drinks.filter { !$0.value.inStock }.keys)
    }

    private func reset() {
        lock.lock()
        drinks = [:]
        current = false
        lock.unlock()
    }

    private func handle(_ msg: [String: Any]) {
        if let change = msg["documentChange"] as? [String: Any],
           let doc = change["document"] as? [String: Any],
           let name = doc["name"] as? String {
            let fields = doc["fields"] as? [String: Any] ?? [:]
            lock.lock()
            drinks[FS.lastPathComponent(name)] = DrinkStock(
                name: FS.string(fields, "name") ?? "",
                inStock: FS.bool(fields, "enabled") ?? true
            )
            lock.unlock()
            emit()
        } else if let removed = ((msg["documentDelete"] ?? msg["documentRemove"]) as? [String: Any])?["document"] as? String {
            lock.lock()
            drinks.removeValue(forKey: FS.lastPathComponent(removed))
            lock.unlock()
            emit()
        } else if let change = msg["targetChange"] as? [String: Any],
                  change["targetChangeType"] as? String == "CURRENT" {
            // The server has delivered the whole collection.
            lock.lock()
            current = true
            lock.unlock()
            emit()
        } else if let filter = msg["filter"] as? [String: Any], let count = filter["count"] as? Int {
            // Existence filter: a mismatch means we missed removals.
            lock.lock()
            let local = drinks.count
            lock.unlock()
            if count != local {
                log("stock listener filter mismatch (server \(count), local \(local)) — resyncing")
                inner.resync()
            }
        }
    }

    private func emit() {
        lock.lock()
        let snapshot = drinks
        let current = self.current
        lock.unlock()
        guard current else { return }
        DispatchQueue.main.async { [onUpdate] in onUpdate?(snapshot) }
    }
}

extension NSMenuItem {
    /// Strikes the title through and disables the item.
    func markOutOfStock(font: NSFont = .menuFont(ofSize: 0)) {
        isEnabled = false
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: NSColor.disabledControlTextColor,
        ])
    }
}
