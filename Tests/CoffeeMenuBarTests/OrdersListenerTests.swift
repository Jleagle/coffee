import Testing
@testable import CoffeeMenuBar

/// The snapshot the orders listener builds from its document mirror on every
/// change: all of today's orders in every status, so the status tracker can
/// spot yours moving along.
@Suite struct OrdersListenerTests {
    private func doc(_ timestamp: Int64, _ status: String, user: String, drink: String) -> OrdersListener.OrderDoc {
        OrdersListener.OrderDoc(timestamp: timestamp, status: status, userName: user, drinkName: drink, userID: user)
    }

    @Test func reportsEveryStatusFromTodayOldestFirst() {
        let docs = [
            "late": doc(300, "cancelled", user: "sam", drink: "Mocha"),
            "early": doc(100, "completed", user: "james", drink: "Latte"),
            "yesterday": doc(50, "queuing", user: "james", drink: "Flat White"),
        ]
        let orders = OrdersListener.todaysOrders(docs, uid: "james", startOfDay: 60)
        #expect(orders.map(\.id) == ["early", "late"])
        #expect(orders.map(\.status) == ["completed", "cancelled"])
        #expect(orders.map(\.drinkName) == ["Latte", "Mocha"])
        #expect(orders.map(\.isMine) == [true, false])
    }

    @Test func nothingIsYoursWithoutAUserID() {
        let docs = ["a": doc(100, "queuing", user: "", drink: "Latte")]
        #expect(OrdersListener.todaysOrders(docs, uid: "", startOfDay: 0).map(\.isMine) == [false])
    }
}
