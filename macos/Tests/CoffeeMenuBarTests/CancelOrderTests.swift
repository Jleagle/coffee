import Testing
@testable import CoffeeMenuBar

@Suite struct CancelOrderTests {
    private func order(mine: Bool, status: String) -> QueuedOrder {
        QueuedOrder(id: "abc123", userName: "James", drinkName: "Latte", status: status, isMine: mine)
    }

    // MARK: - Which orders get a "Cancel" item

    @Test func ownQueuingOrderIsCancellable() {
        #expect(order(mine: true, status: "queuing").isCancellable)
    }

    @Test func ownOrderBeingPreparedIsNotCancellable() {
        // Matches the web app, which hides Cancel once the barista has started.
        #expect(!order(mine: true, status: "being-prepared").isCancellable)
    }

    @Test func someoneElsesQueuingOrderIsNotCancellable() {
        #expect(!order(mine: false, status: "queuing").isCancellable)
    }

    // MARK: - The Firestore write

    @Test func patchURLMasksOnlyTheUpdatedFieldsAndRequiresTheDocumentToExist() {
        // Without an update mask a PATCH replaces the whole document, wiping
        // every other field on the order.
        let url = FirestoreClient.patchURL(
            documentsBase: "https://firestore.googleapis.com/v1/projects/p/databases/(default)/documents",
            collection: "order",
            id: "abc123",
            updating: ["status", "lastUpdatedTimestamp"]
        )
        #expect(
            url == "https://firestore.googleapis.com/v1/projects/p/databases/(default)/documents/order/abc123"
                + "?updateMask.fieldPaths=status&updateMask.fieldPaths=lastUpdatedTimestamp&currentDocument.exists=true"
        )
    }

    @Test func cancelledFieldsMatchTheWebAppWrite() {
        let fields = OrderService.cancelledFields(nowMs: 1_700_000_000_000)
        #expect(fields.keys.sorted() == ["lastUpdatedTimestamp", "status"])
        #expect((fields["status"] as? [String: Any])?["stringValue"] as? String == "cancelled")
        #expect((fields["lastUpdatedTimestamp"] as? [String: Any])?["integerValue"] as? String == "1700000000000")
    }
}
