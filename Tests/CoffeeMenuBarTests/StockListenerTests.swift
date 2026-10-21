import Testing
@testable import CoffeeMenuBar

/// Which drinks count as out of stock, and which stock changes get announced.
@Suite struct StockListenerTests {
    private let latte = DrinkStock(name: "Latte", inStock: true)
    private let noLatte = DrinkStock(name: "Latte", inStock: false)
    private let mocha = DrinkStock(name: "Mocha", inStock: true)
    private let noMocha = DrinkStock(name: "Mocha", inStock: false)

    @Test func onlyDisabledDrinksAreOutOfStock() {
        #expect(StockListener.outOfStock(["latte": latte, "mocha": noMocha]) == ["mocha"])
    }

    @Test func runningOutAndComingBackAreAnnounced() {
        let messages = AppDelegate.stockNotifications(
            from: ["latte": latte, "mocha": noMocha],
            to: ["latte": noLatte, "mocha": mocha],
            watching: ["latte", "mocha"]
        )
        #expect(messages.map(\.kind) == [.drinkOutOfStock, .drinkBackInStock])
        #expect(messages.map(\.body) == ["Latte is out of stock.", "Mocha is back in stock."])
    }

    @Test func drinksYouHaventOrderedAreSilent() {
        let messages = AppDelegate.stockNotifications(from: ["latte": latte], to: ["latte": noLatte], watching: ["mocha"])
        #expect(messages.isEmpty)
    }

    @Test func drinksAddedOrRemovedAreSilent() {
        #expect(AppDelegate.stockNotifications(from: ["latte": noLatte], to: [:], watching: ["latte"]).isEmpty)
        #expect(AppDelegate.stockNotifications(from: [:], to: ["latte": noLatte], watching: ["latte"]).isEmpty)
    }

    @Test func unchangedStockIsSilent() {
        #expect(AppDelegate.stockNotifications(from: ["latte": noLatte], to: ["latte": noLatte], watching: ["latte"]).isEmpty)
    }
}
