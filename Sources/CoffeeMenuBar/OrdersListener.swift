import Foundation

/// One of today's orders as the listener sees it. The queued ones fill the
/// dropdown's cancel section and optional queue section; all of them feed the
/// status tracker.
struct Order: Sendable {
    /// The Firestore document ID, needed to cancel the order.
    let id: String
    let userName: String
    let drinkName: String
    /// "queuing", "being-prepared", "completed" or "cancelled".
    let status: String
    /// Whether the signed-in user placed this order.
    let isMine: Bool

    /// You can cancel your own order only while it is still queuing — once
    /// the barista has started on it, it's yours. Matches the web app.
    var isCancellable: Bool { isMine && status == "queuing" }
}

/// Live view of today's orders via a Firestore query listen — no polling.
/// Maintains a local mirror of the result set (rebuilt free of charge on
/// every reconnect) and reports the queue whenever anything changes.
final class OrdersListener: @unchecked Sendable {
    struct OrderDoc {
        let timestamp: Int64
        let status: String
        let userName: String
        let drinkName: String
        let userID: String
    }

    private let inner: FirestoreListener
    private let uid: String
    private let lock = NSLock()
    private var orders: [String: OrderDoc] = [:]

    /// (people queuing, non-cancelled orders today, queuing orders oldest
    /// first) — called on the main queue.
    var onUpdate: ((Int, Int, [Order]) -> Void)?
    /// Every order seen today, oldest first — called on the main queue, so
    /// your orders changing status can be noticed.
    var onOrders: (([Order]) -> Void)?

    init(config: AppConfig, session: SessionStore, uid: String) {
        self.uid = uid
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
        return nowMs - nowMs % 86_400_000 // midnight UTC
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
                drinkName: FS.string(fields, "drinkName") ?? "?",
                userID: FS.string(fields, "userId") ?? ""
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
        lock.lock()
        let snapshot = orders
        lock.unlock()

        // The query is anchored at the midnight before the last (re)connect,
        // so filter client-side too in case the day rolled over mid-stream.
        let today = Self.todaysOrders(snapshot, uid: uid, startOfDay: Self.startOfToday())
        let total = today.filter { $0.status != "cancelled" }.count
        let queued = today.filter { $0.status == "queuing" || $0.status == "being-prepared" }

        DispatchQueue.main.async { [onUpdate, onOrders] in
            onUpdate?(queued.count, total, queued)
            onOrders?(today)
        }
    }

    /// Today's orders from the mirror, oldest first, with the signed-in
    /// user's marked as theirs.
    static func todaysOrders(_ docs: [String: OrderDoc], uid: String, startOfDay: Int64) -> [Order] {
        docs
            .filter { $0.value.timestamp > startOfDay }
            .sorted { $0.value.timestamp < $1.value.timestamp }
            .map { id, doc in
                Order(
                    id: id,
                    userName: doc.userName,
                    drinkName: doc.drinkName,
                    status: doc.status,
                    isMine: !uid.isEmpty && doc.userID == uid
                )
            }
    }
}
