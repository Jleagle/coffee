import Foundation

/// Polls today's orders once a minute and reports the queue size, using the
/// same query and counting rules as the CLI's `queue` command.
final class QueueService: @unchecked Sendable {
    private let client: FirestoreClient
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var pollingEnabled = false
    private var burstUntil = Date.distantPast
    private var lastRefresh = Date.distantPast

    /// (people queuing, non-cancelled orders today) — called on the main queue.
    var onUpdate: ((Int, Int) -> Void)?
    var onError: ((String) -> Void)?

    init(client: FirestoreClient) {
        self.client = client
    }

    /// Auto-refresh only runs while the shop is open; manual refreshNow()
    /// always works.
    func setPolling(_ enabled: Bool) {
        lock.lock()
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
        guard pollingEnabled else { return false }
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

            var queuing = 0
            var total = 0
            for doc in docs {
                let fields = doc["fields"] as? [String: Any] ?? [:]
                let status = FS.string(fields, "status") ?? ""
                if status != "cancelled" { total += 1 }
                if status == "queuing" || status == "being-prepared" { queuing += 1 }
            }
            log("queue refresh: \(queuing) queuing, \(total) orders today")
            DispatchQueue.main.async { [onUpdate] in onUpdate?(queuing, total) }
        } catch {
            let msg = error.localizedDescription
            log("queue refresh failed: \(msg)")
            DispatchQueue.main.async { [onError] in onError?(msg) }
        }
    }
}
