import Foundation

/// Places orders with the same document shape the Go CLI writes, and records
/// the order in ~/.coffee.json so it can be reordered later.
final class OrderService: @unchecked Sendable {
    private let client: FirestoreClient
    private let session: SessionStore
    private let config: AppConfig

    init(client: FirestoreClient, session: SessionStore, config: AppConfig) {
        self.client = client
        self.session = session
        self.config = config
    }

    /// Returns the queue position (nil if it couldn't be determined) and the
    /// LastOrder that was saved to ~/.coffee.json.
    func place(drinkID: String, drinkName: String, options: [SelectedOption], shots: Int) async throws -> (position: Int?, last: LastOrder) {
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

        try await client.createDocument(collection: "order", fields: fields)

        let position = try? await queuePosition(at: nowMs)

        let last = LastOrder(
            drinkID: drinkID,
            drinkName: drinkName,
            shots: shots,
            options: options.map { LastOrderOption(collection: $0.collection, id: $0.id, name: $0.name, count: $0.count) },
            placedAt: ISO8601DateFormatter().string(from: Date())
        )
        await session.saveLastOrder(last)

        return (position, last)
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
