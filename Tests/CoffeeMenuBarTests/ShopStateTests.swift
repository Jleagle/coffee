import Testing
@testable import CoffeeMenuBar

/// Which shop state changes get announced through Notification Center.
@Suite struct ShopStateTests {
    @Test func openingIsAnnounced() {
        let message = AppDelegate.shopNotification(from: .closed, to: .open)
        #expect(message?.title == "Shop open")
        #expect(message?.body == "The coffee shop is now open.")
    }

    @Test func closingIsAnnounced() {
        let message = AppDelegate.shopNotification(from: .open, to: .closed)
        #expect(message?.title == "Shop closed")
        #expect(message?.body == "The coffee shop is now closed.")
    }

    @Test func changesInvolvingUnknownAreSilent() {
        // Startup, and the listener dropping and reconnecting, both pass
        // through .unknown; neither is the shop actually opening or closing.
        #expect(AppDelegate.shopNotification(from: .unknown, to: .open) == nil)
        #expect(AppDelegate.shopNotification(from: .unknown, to: .closed) == nil)
        #expect(AppDelegate.shopNotification(from: .open, to: .unknown) == nil)
        #expect(AppDelegate.shopNotification(from: .closed, to: .unknown) == nil)
    }

    @Test func repeatedStateIsSilent() {
        // The listener re-delivers the document on every reconnect.
        #expect(AppDelegate.shopNotification(from: .open, to: .open) == nil)
        #expect(AppDelegate.shopNotification(from: .closed, to: .closed) == nil)
    }
}
