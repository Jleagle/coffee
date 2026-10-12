import Testing
@testable import CoffeeMenuBar

/// Spotting your orders change status between orders-listener updates.
@Suite struct OrderStatusTrackerTests {
    private func order(_ id: String, _ status: String, drink: String = "Latte", mine: Bool = true) -> Order {
        Order(id: id, userName: "James", drinkName: drink, status: status, isMine: mine)
    }

    @Test func firstSightingIsNeverNews() {
        // Startup, reconnects and a freshly placed order all deliver orders
        // the tracker hasn't seen; none of that is a change.
        let tracker = OrderStatusTracker()
        #expect(tracker.note([order("a", "queuing")]).isEmpty)
        #expect(tracker.note([order("a", "queuing"), order("b", "being-prepared")]).isEmpty)
    }

    @Test func eachChangeIsReportedOnce() {
        let tracker = OrderStatusTracker()
        _ = tracker.note([order("a", "queuing")])
        #expect(tracker.note([order("a", "being-prepared")]) == [OrderStatusChange(id: "a", drinkName: "Latte", status: "being-prepared")])
        #expect(tracker.note([order("a", "being-prepared")]).isEmpty)
        #expect(tracker.note([order("a", "completed")]) == [OrderStatusChange(id: "a", drinkName: "Latte", status: "completed")])
        #expect(tracker.note([order("a", "completed")]).isEmpty)
    }

    @Test func otherPeoplesOrdersAreIgnored() {
        let tracker = OrderStatusTracker()
        _ = tracker.note([order("a", "queuing", mine: false)])
        #expect(tracker.note([order("a", "completed", mine: false)]).isEmpty)
    }

    @Test func cancellationsAreReported() {
        let tracker = OrderStatusTracker()
        _ = tracker.note([order("a", "queuing")])
        #expect(tracker.note([order("a", "cancelled")]) == [OrderStatusChange(id: "a", drinkName: "Latte", status: "cancelled")])
    }

    @Test func aCancellationTheAppMadeItselfIsSwallowed() {
        // The menu's Cancel already posts its own confirmation.
        let tracker = OrderStatusTracker()
        _ = tracker.note([order("a", "queuing")])
        tracker.expectCancellation(of: "a")
        #expect(tracker.note([order("a", "cancelled")]).isEmpty)
    }

    @Test func aFailedCancelLeavesLaterCancellationsAsNews() {
        let tracker = OrderStatusTracker()
        _ = tracker.note([order("a", "queuing")])
        tracker.expectCancellation(of: "a")
        tracker.forgetExpectedCancellation(of: "a")
        #expect(tracker.note([order("a", "cancelled")]).count == 1)
    }

    @Test func changesKeepTheOrderTheyWereGivenIn() {
        // The listener sends oldest first; "Your Latte and Flat White are
        // ready." should read in that order too.
        let tracker = OrderStatusTracker()
        _ = tracker.note([order("a", "queuing", drink: "Latte"), order("b", "queuing", drink: "Flat White")])
        let changes = tracker.note([order("a", "completed", drink: "Latte"), order("b", "completed", drink: "Flat White")])
        #expect(changes.map(\.drinkName) == ["Latte", "Flat White"])
    }

    @Test func anOrderMissingFromAnUpdateIsStillRemembered() {
        // After a reconnect the server re-sends the day one document at a
        // time, so updates are briefly partial. Re-delivery of an unchanged
        // order is quiet; a change that landed while disconnected is news.
        let tracker = OrderStatusTracker()
        _ = tracker.note([order("a", "queuing"), order("b", "queuing")])
        #expect(tracker.note([order("a", "queuing")]).isEmpty)
        #expect(tracker.note([order("a", "queuing"), order("b", "queuing")]).isEmpty)
        #expect(tracker.note([order("a", "queuing"), order("b", "completed")]).map(\.id) == ["b"])
    }
}
