import Foundation

/// An order held back by the "Only Order When Open" setting, waiting for the
/// shop to open. In-memory only; forgotten on restart.
struct DeferredOrder: Sendable {
    /// Identifies the held order so the menu's Cancel item can drop it.
    let id = UUID().uuidString
    let drinkID: String
    let drinkName: String
    let options: [SelectedOption]
    let shots: Int
}

enum PlaceOutcome: Sendable {
    case placed(position: Int?, last: LastOrder)
    case deferredUntilOpen
}

/// Places orders with the same document shape the Go CLI writes, and records
/// the order in the recents so it can be reordered later.
final class OrderService: @unchecked Sendable {
    private let client: FirestoreClient
    private let session: SessionStore
    private let config: AppConfig

    // Orders placed by this app that haven't finished yet (doc ID → drink
    // name), so the app can flash the icon and post a notification when one is
    // ready. In-memory only; forgotten on restart.
    private let pendingLock = NSLock()
    private var pendingOrders: [String: String] = [:]
    private var deferredOrders: [DeferredOrder] = []
    private var shopOpen = false

    init(client: FirestoreClient, session: SessionStore, config: AppConfig) {
        self.client = client
        self.session = session
        self.config = config
    }

    /// Kept up to date by AppDelegate so place() can hold orders back while
    /// the shop is closed (when the setting asks for that).
    func setShopOpen(_ open: Bool) {
        pendingLock.lock()
        shopOpen = open
        pendingLock.unlock()
    }

    /// Hands over (and clears) the orders deferred while the shop was closed.
    func takeDeferred() -> [DeferredOrder] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let orders = deferredOrders
        deferredOrders = []
        return orders
    }

    /// The orders currently held back, oldest first, for the menu's Cancel
    /// items.
    func heldOrders() -> [DeferredOrder] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return deferredOrders
    }

    /// Drops a held order so it is never placed. Nothing has been written to
    /// Firestore, so there is nothing else to undo. Returns false if the
    /// order was no longer held — the shop opened and the flush already took
    /// it — in which case nothing changed.
    @discardableResult
    func removeDeferred(id: String) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let before = deferredOrders.count
        deferredOrders.removeAll { $0.id == id }
        return deferredOrders.count != before
    }

    /// Stashes the order when "Only Order When Open" is on and the shop isn't
    /// open; returns whether it did.
    private func deferIfClosed(_ order: DeferredOrder) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard Settings.onlyOrderWhenOpen && !shopOpen else { return false }
        deferredOrders.append(order)
        return true
    }

    /// Places the order, or — with "Only Order When Open" enabled while the
    /// shop isn't open — holds it until AppDelegate flushes it on opening.
    func place(drinkID: String, drinkName: String, options: [SelectedOption], shots: Int) async throws -> PlaceOutcome {
        if deferIfClosed(DeferredOrder(drinkID: drinkID, drinkName: drinkName, options: options, shots: shots)) {
            return .deferredUntilOpen
        }

        let info = await session.info()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let optionValues: [[String: Any]] = options.map { o in
            FS.map([
                "collection": FS.s(o.collection),
                "optionName": FS.s(o.name),
                "optionId": FS.s(o.id),
                "optionRef": FS.ref("\(config.database)/documents/\(o.collection)/\(o.id)"),
                "count": FS.i(Int64(o.count)),
            ])
        }

        let fields: [String: Any] = [
            "userName": FS.s(info.displayName),
            "userEmail": FS.s(info.email),
            "userId": FS.s(info.uid),
            "orderTimestamp": FS.i(nowMs),
            "options": FS.arr(optionValues),
            "status": FS.s("queuing"),
            "drinkName": FS.s(drinkName),
            "drinkId": FS.s(drinkID),
            "lastUpdatedTimestamp": FS.i(nowMs),
        ]

        let name = try await client.createDocument(collection: "order", fields: fields)
        trackPending(name, drinkName: drinkName)

        let position = try? await queuePosition(at: nowMs)

        let last = LastOrder(
            drinkID: drinkID,
            drinkName: drinkName,
            shots: shots,
            options: options.map { LastOrderOption(collection: $0.collection, id: $0.id, name: $0.name, count: $0.count) },
            placedAt: ISO8601DateFormatter().string(from: Date())
        )
        await session.saveRecentOrder(last)

        return .placed(position: position, last: last)
    }

    /// Remembers an order this app placed (by its full document name) so
    /// notePendingStatuses can report when it's ready.
    func trackPending(_ name: String, drinkName: String) {
        pendingLock.lock()
        pendingOrders[FS.lastPathComponent(name)] = drinkName
        pendingLock.unlock()
    }

    /// Checks the orders listener's doc ID → status map against the orders
    /// this app placed. Returns the drink names of any that just completed,
    /// each reported once; a cancelled order stops being tracked without
    /// triggering anything.
    func notePendingStatuses(_ statuses: [String: String]) -> [String] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        var ready: [String] = []
        for (id, drinkName) in pendingOrders {
            switch statuses[id] {
            case "completed":
                pendingOrders[id] = nil
                ready.append(drinkName)
            case "cancelled":
                pendingOrders[id] = nil
            default:
                break
            }
        }
        return ready
    }

    /// The fields the web app's Cancel button writes.
    static func cancelledFields(nowMs: Int64) -> [String: Any] {
        [
            "status": FS.s("cancelled"),
            "lastUpdatedTimestamp": FS.i(nowMs),
        ]
    }

    /// Cancels one of the signed-in user's orders (placed from any client) by
    /// flipping its status, the same write the web app does. The orders
    /// listener notices the change and drops it from the queue.
    func cancel(orderID: String) async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try await client.patchDocument(collection: "order", id: orderID, fields: Self.cancelledFields(nowMs: nowMs))
    }

    private func queuePosition(at orderMs: Int64) async throws -> Int {
        let startOfDay = orderMs - orderMs % 86_400_000
        let docs = try await client.runQuery([
            "from": [["collectionId": "order"]],
            "where": ["compositeFilter": [
                "op": "AND",
                "filters": [
                    ["fieldFilter": [
                        "field": ["fieldPath": "orderTimestamp"],
                        "op": "GREATER_THAN",
                        "value": ["integerValue": String(startOfDay)],
                    ]],
                    ["fieldFilter": [
                        "field": ["fieldPath": "orderTimestamp"],
                        "op": "LESS_THAN",
                        "value": ["integerValue": String(orderMs)],
                    ]],
                ],
            ]],
        ])

        let ahead = docs.filter { doc in
            let fields = doc["fields"] as? [String: Any] ?? [:]
            let status = FS.string(fields, "status") ?? ""
            return status == "queuing" || status == "being-prepared"
        }.count

        return ahead + 1
    }
}
