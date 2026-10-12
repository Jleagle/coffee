import Testing
@testable import CoffeeMenuBar

/// The notifications posted when one of your orders changes status.
@Suite struct OrderStatusNotificationTests {
    private func change(_ status: String, drink: String = "Latte") -> OrderStatusChange {
        OrderStatusChange(id: drink, drinkName: drink, status: status)
    }

    private func lines(_ changes: [OrderStatusChange]) -> [String] {
        AppDelegate.notifications(for: changes).map { "\($0.title) | \($0.body)" }
    }

    @Test func beingPreparedIsAnnounced() {
        #expect(lines([change("being-prepared")]) == ["Order being prepared | Your Latte is being prepared."])
    }

    @Test func cancellationIsAnnounced() {
        #expect(lines([change("cancelled")]) == ["Order cancelled | Your Latte was cancelled."])
    }

    @Test func ordersReadyTogetherShareOneNotification() {
        #expect(lines([change("completed", drink: "Latte"), change("completed", drink: "Flat White")])
            == ["Order ready | Your Latte and Flat White are ready."])
    }

    @Test func otherStatusesAreQuiet() {
        #expect(lines([change("queuing"), change("something-new")]).isEmpty)
    }

    @Test func readyTextReadsNaturally() {
        #expect(AppDelegate.readyText(["Latte"]) == "Your Latte is ready.")
        #expect(AppDelegate.readyText(["Latte", "Flat White"]) == "Your Latte and Flat White are ready.")
        #expect(AppDelegate.readyText(["Latte", "Mocha", "Flat White"]) == "Your Latte, Mocha and Flat White are ready.")
    }
}
