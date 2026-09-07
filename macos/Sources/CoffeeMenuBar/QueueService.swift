import Foundation

/// One order currently in the queue, for the dropdown's queue section.
struct QueuedOrder: Sendable {
    let userName: String
    let drinkName: String
}

/// Polls today's orders once a minute and reports the queue size, using the
/// same query and counting rules as the CLI's `queue` command.
final class QueueService: @unchecked Sendable {
    private let client: FirestoreClient
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var pollingEnabled = false
    private var pollUntil = Date.distantPast
    private var burstUntil = Date.distantPast
    private var lastRefresh = Date.distantPast

    /// (people queuing, non-cancelled orders today, queuing orders oldest
    /// first) — called on the main queue.
    var onUpdate: ((Int, Int, [QueuedOrder]) -> Void)?
    /// Doc ID → status for every order fetched today — called on the main
    /// queue, so completions of orders this app placed can be noticed.
    var onStatuses: (([String: String]) -> Void)?
    var onError: ((String) -> Void)?

    init(client: FirestoreClient) {
        self.client = client
    }

    /// Auto-refresh runs while the shop is open, plus 5 minutes after it
    /// closes (so the tail of the queue gets worked off on screen); manual
    /// refreshNow() always works.
    func setPolling(_ enabled: Bool) {
        lock.lock()
        if !enabled && pollingEnabled {
            // Only on a real open→closed transition — the shop listener
            // re-delivers "closed" on every reconnect, which must not keep
            // extending the window.
            pollUntil = Date().addingTimeInterval(300)
        }
        pollingEnabled = enabled
        lock.unlock()
    }

    /// Refresh every 10 seconds until the deadline (the busy window right
    /// after the shop opens), then fall back to once a minute.
    func beginBurst(seconds: TimeInterval) {
        lock.lock()
        burstUntil = Date().addingTimeInterval(seconds)
        lock.unlock()
    }

    private var shouldRefreshNow: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pollingEnabled || Date() < pollUntil else { return false }
        if Date() < burstUntil { return true }
        return Date().timeIntervalSince(lastRefresh) >= 59
    }

    func start() {
        // The loop ticks every 10 seconds; each tick refreshes only during a
        // burst window or once ~60 seconds have passed since the last refresh.
        task = Task { [weak self] in
            // One initial fetch so the count isn't blank at launch, then only
            // poll while the shop is open.
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.shouldRefreshNow {
                    await self.refresh()
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    func refreshNow() {
        Task { [weak self] in await self?.refresh() }
    }

    private func refresh() async {
        lock.lock()
        lastRefresh = Date()
        lock.unlock()
        do {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let startOfDay = nowMs - nowMs % 86_400_000 // midnight UTC, matching the CLI's Truncate
            let docs = try await client.runQuery([
                "from": [["collectionId": "order"]],
                "where": ["fieldFilter": [
                    "field": ["fieldPath": "orderTimestamp"],
                    "op": "GREATER_THAN",
                    "value": ["integerValue": String(startOfDay)],
                ]],
                "orderBy": [["field": ["fieldPath": "orderTimestamp"], "direction": "ASCENDING"]],
            ])

            var total = 0
            var queued: [QueuedOrder] = []
            var statuses: [String: String] = [:]
            for doc in docs {
                let fields = doc["fields"] as? [String: Any] ?? [:]
                let status = FS.string(fields, "status") ?? ""
                if let name = doc["name"] as? String {
                    statuses[FS.lastPathComponent(name)] = status
                }
                if status != "cancelled" { total += 1 }
                if status == "queuing" || status == "being-prepared" {
                    // The query orders by orderTimestamp ascending, so `queued`
                    // is already oldest first.
                    queued.append(QueuedOrder(
                        userName: FS.string(fields, "userName") ?? "?",
                        drinkName: FS.string(fields, "drinkName") ?? "?"
                    ))
                }
            }
            log("queue refresh: \(queued.count) queuing, \(total) orders today")
            DispatchQueue.main.async { [onUpdate, onStatuses] in
                onUpdate?(queued.count, total, queued)
                onStatuses?(statuses)
            }
        } catch {
            let msg = error.localizedDescription
            log("queue refresh failed: \(msg)")
            DispatchQueue.main.async { [onError] in onError?(msg) }
        }
    }
}
