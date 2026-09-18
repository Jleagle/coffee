import Testing
@testable import CoffeeMenuBar

/// Deciding when to flash the icon and alert that an order this app placed
/// is ready.
@Suite struct OrderReadyTests {
    private func service() -> OrderService {
        let session = SessionStore()
        let config = AppConfig(projectID: "p", apiKey: "k")
        return OrderService(client: FirestoreClient(config: config, session: session), session: session, config: config)
    }

    private let docs = "projects/p/databases/(default)/documents/order"

    @Test func completedOrdersAreReportedOnceByDrinkName() {
        let service = service()
        service.trackPending("\(docs)/aaa", drinkName: "Latte")
        service.trackPending("\(docs)/bbb", drinkName: "Flat White")

        // Nothing to say while both are still in the queue.
        #expect(service.notePendingStatuses(["aaa": "queuing", "bbb": "being-prepared"]).isEmpty)

        #expect(service.notePendingStatuses(["aaa": "completed", "bbb": "being-prepared"]) == ["Latte"])
        // Reported once — the next listener update must not alert again.
        #expect(service.notePendingStatuses(["aaa": "completed", "bbb": "being-prepared"]).isEmpty)
        #expect(service.notePendingStatuses(["aaa": "completed", "bbb": "completed"]) == ["Flat White"])
    }

    @Test func cancelledOrdersAreForgottenSilently() {
        let service = service()
        service.trackPending("\(docs)/aaa", drinkName: "Latte")
        #expect(service.notePendingStatuses(["aaa": "cancelled"]).isEmpty)
        #expect(service.notePendingStatuses(["aaa": "completed"]).isEmpty)
    }

    @Test func ordersPlacedElsewhereAreIgnored() {
        let service = service()
        #expect(service.notePendingStatuses(["zzz": "completed"]).isEmpty)
    }

    @Test func readyTextReadsNaturally() {
        #expect(AppDelegate.readyText(["Latte"]) == "Your Latte is ready.")
        #expect(AppDelegate.readyText(["Latte", "Flat White"]) == "Your Latte and Flat White are ready.")
        #expect(AppDelegate.readyText(["Latte", "Mocha", "Flat White"]) == "Your Latte, Mocha and Flat White are ready.")
    }
}
