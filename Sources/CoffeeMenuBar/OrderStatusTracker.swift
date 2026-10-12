import Foundation

/// One of your orders moving to a new status.
struct OrderStatusChange: Equatable, Sendable {
    let id: String
    let drinkName: String
    /// The status it has just reached.
    let status: String
}

/// Spots your orders changing status between orders-listener updates, so the
/// app can announce being-prepared, ready and cancelled.
///
/// Remembers the last status seen for each of your orders. An order's first
/// sighting is never a change, which keeps startup, reconnects and your own
/// freshly placed orders quiet. The memory outlives listener resets, so a
/// change that landed while the laptop slept is still reported on reconnect.
/// Called on the main queue.
final class OrderStatusTracker {
    private var lastStatus: [String: String] = [:]
    private var expectedCancellations: Set<String> = []

    /// Marks an order this app is about to cancel itself, so the resulting
    /// cancellation isn't announced as news.
    func expectCancellation(of id: String) {
        expectedCancellations.insert(id)
    }

    /// Undoes expectCancellation when the cancel write failed.
    func forgetExpectedCancellation(of id: String) {
        expectedCancellations.remove(id)
    }

    /// Takes the listener's latest view of today's orders and returns the
    /// changes to yours, in the order given.
    func note(_ orders: [Order]) -> [OrderStatusChange] {
        var changes: [OrderStatusChange] = []
        for order in orders where order.isMine {
            let previous = lastStatus.updateValue(order.status, forKey: order.id)
            guard let previous, previous != order.status else { continue }
            if order.status == "cancelled", expectedCancellations.remove(order.id) != nil {
                continue
            }
            changes.append(OrderStatusChange(id: order.id, drinkName: order.drinkName, status: order.status))
        }
        return changes
    }
}
