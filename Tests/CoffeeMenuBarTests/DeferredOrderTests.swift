import Foundation
import Testing
@testable import CoffeeMenuBar

/// The in-memory holding pen behind "Only Order When Open", and the Cancel
/// items the menu builds from it. Serialized because it toggles the setting
/// in UserDefaults.
@Suite(.serialized) struct DeferredOrderTests {
    private func service() -> OrderService {
        let session = SessionStore()
        let config = AppConfig(projectID: "p", apiKey: "k")
        return OrderService(client: FirestoreClient(config: config, session: session), session: session, config: config)
    }

    /// Runs `body` with the setting on and the shop closed, so place() holds
    /// orders instead of writing them (no network involved).
    private func withShopClosed(_ body: (OrderService) async throws -> Void) async throws {
        let previous = UserDefaults.standard.object(forKey: "onlyOrderWhenOpen")
        Settings.onlyOrderWhenOpen = true
        defer { UserDefaults.standard.set(previous, forKey: "onlyOrderWhenOpen") }
        let service = service()
        service.setShopOpen(false)
        try await body(service)
    }

    private func isDeferred(_ outcome: PlaceOutcome) -> Bool {
        if case .deferredUntilOpen = outcome { return true }
        return false
    }

    @Test func heldOrderCanBeCancelledBeforeTheShopOpens() async throws {
        try await withShopClosed { service in
            let latte = try await service.place(drinkID: "d1", drinkName: "Latte", options: [], shots: 1)
            let flatWhite = try await service.place(drinkID: "d2", drinkName: "Flat White", options: [], shots: 2)
            #expect(isDeferred(latte))
            #expect(isDeferred(flatWhite))

            let held = service.heldOrders()
            #expect(held.map(\.drinkName) == ["Latte", "Flat White"])

            #expect(service.removeDeferred(id: held[0].id))
            #expect(service.heldOrders().map(\.drinkName) == ["Flat White"])

            // The flush on opening only gets what's left, and empties the pen.
            #expect(service.takeDeferred().map(\.drinkName) == ["Flat White"])
            #expect(service.heldOrders().isEmpty)
        }
    }

    @Test func cancellingAnOrderTheFlushAlreadyTookChangesNothing() async throws {
        try await withShopClosed { service in
            _ = try await service.place(drinkID: "d1", drinkName: "Latte", options: [], shots: 1)
            let id = service.heldOrders()[0].id
            _ = service.takeDeferred()
            #expect(!service.removeDeferred(id: id))
            #expect(service.heldOrders().isEmpty)
        }
    }

    @Test func eachHeldOrderGetsItsOwnID() {
        // Two identical reorders must be cancellable independently.
        let a = DeferredOrder(drinkID: "d", drinkName: "Latte", options: [], shots: 1)
        let b = DeferredOrder(drinkID: "d", drinkName: "Latte", options: [], shots: 1)
        #expect(a.id != b.id)
    }
}
