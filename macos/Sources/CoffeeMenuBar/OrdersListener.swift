import Foundation

/// One order currently in the queue, for the dropdown's optional queue section.
struct QueuedOrder: Sendable {
    let userName: String
    let drinkName: String
}

/// Live view of today's orders via a Firestore query listen — no polling.
/// Maintains a local mirror of the result set (rebuilt free of charge on
/// every reconnect) and reports the queue whenever anything changes, using
/// the same counting rules as the CLI's `queue` command.
final class OrdersListener: @unchecked Sendable {
    private struct OrderDoc {
        let timestamp: Int64
        let status: String
        let userName: String
        let drinkName: String
    }

    private let inner: FirestoreListener
    private let lock = NSLock()
    private var orders: [String: OrderDoc] = [:]

    /// (people queuing, non-cancelled orders today, queuing orders oldest
    /// first) — called on the main queue.
    var onUpdate: ((Int, Int, [QueuedOrder]) -> Void)?
    /// Doc ID → status for every order seen today — called on the main queue,
    /// so completions of orders this app placed can be noticed.
    var onStatuses: (([String: String]) -> Void)?

    init(config: AppConfig, session: SessionStore) {
        inner = FirestoreListener(config: config, session: session) {
            [
                "query": [
                    "parent": "\(config.database)/documents",
                    "structuredQuery": [
                        "from": [["collectionId": "order"]],
                        "where": ["fieldFilter": [
                            "field": ["fieldPath": "orderTimestamp"],
                            "op": "GREATER_THAN",
                            "value": ["integerValue": String(Self.startOfToday())],
                        ]],
                    ],
                ] as [String: Any],
                "targetId": 1,
            ]
        }
        inner.onReset = { [weak self] in self?.reset() }
        inner.onMessage = { [weak self] msg in self?.handle(msg) }
    }

    func start() { inner.start() }
    func stop() { inner.stop() }

    /// Forces a reconnect; the fresh handshake re-delivers the full day's
    /// orders (and re-anchors the query at the current day's midnight).
    func refreshNow() { inner.resync() }

    private static func startOfToday() -> Int64 {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return nowMs - nowMs % 86_400_000 // midnight UTC, matching the CLI's Truncate
    }

    private func reset() {
        lock.lock()
        orders = [:]
        lock.unlock()
        // No emit — the server re-sends the current result set immediately.
    }

    private func handle(_ msg: [String: Any]) {
        if let change = msg["documentChange"] as? [String: Any],
           let doc = change["document"] as? [String: Any],
           let name = doc["name"] as? String {
            let fields = doc["fields"] as? [String: Any] ?? [:]
            lock.lock()
            orders[FS.lastPathComponent(name)] = OrderDoc(
                timestamp: FS.int(fields, "orderTimestamp") ?? 0,
                status: FS.string(fields, "status") ?? "",
                userName: FS.string(fields, "userName") ?? "?",
                drinkName: FS.string(fields, "drinkName") ?? "?"
            )
            lock.unlock()
            emit()
        } else if let removed = ((msg["documentDelete"] ?? msg["documentRemove"]) as? [String: Any])?["document"] as? String {
            lock.lock()
            orders.removeValue(forKey: FS.lastPathComponent(removed))
            lock.unlock()
            emit()
        } else if let filter = msg["filter"] as? [String: Any], let count = filter["count"] as? Int {
            // Existence filter: the server says how many docs should match.
            // A mismatch means we missed removals — reconnect to re-sync.
            lock.lock()
            let local = orders.count
            lock.unlock()
            if count != local {
                log("orders listener filter mismatch (server \(count), local \(local)) — resyncing")
                inner.resync()
            }
        }
    }

    private func emit() {
        // The query is anchored at the midnight before the last (re)connect,
        // so filter client-side too in case the day rolled over mid-stream.
        let startOfDay = Self.startOfToday()
        lock.lock()
        let today = orders.filter { $0.value.timestamp > startOfDay }
        lock.unlock()

        let total = today.values.filter { $0.status != "cancelled" }.count
        let queued = today.values
            .filter { $0.status == "queuing" || $0.status == "being-prepared" }
            .sorted { $0.timestamp < $1.timestamp }
            .map { QueuedOrder(userName: $0.userName, drinkName: $0.drinkName) }
        let statuses = today.mapValues { $0.status }

        DispatchQueue.main.async { [onUpdate, onStatuses] in
            onUpdate?(queued.count, total, queued)
            onStatuses?(statuses)
        }
    }
}
