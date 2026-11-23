import Testing
@testable import CoffeeMenuBar

/// How the drinks and drinkCategories documents become the sections of the
/// New Order window's drink menu.
@Suite struct DrinkSectionsTests {
    private typealias Doc = (id: String, fields: [String: Any])

    private let categoryDocs: [Doc] = [
        (id: "hot", fields: ["name": ["stringValue": "hot"], "order": ["integerValue": "1"]]),
        (id: "cold", fields: ["name": ["stringValue": "cold"], "order": ["integerValue": "2"]]),
        (id: "festive", fields: ["name": ["stringValue": "Festive Menu"]]),
        (id: "popular", fields: ["name": ["stringValue": "popular"]]),
    ]

    private func drinkDoc(_ name: String, in categoryIDs: [String]) -> Doc {
        let refs = categoryIDs.map {
            ["referenceValue": "projects/p/databases/(default)/documents/drinkCategories/\($0)"]
        }
        return (id: name, fields: [
            "name": ["stringValue": name],
            "category": ["arrayValue": ["values": refs]],
        ])
    }

    /// Each section as "<heading>: <drink>, <drink>", top to bottom.
    private func menu(_ drinkDocs: [Doc]) -> [String] {
        Catalog(drinkDocs: drinkDocs, categoryDocs: categoryDocs, options: [:]).sections.map {
            "\($0.name): \($0.drinks.map(\.name).joined(separator: ", "))"
        }
    }

    @Test func aDrinkInNeitherHotNorColdIsStillListed() {
        #expect(menu([drinkDoc("Winter Warmer", in: ["festive"])]) == ["Festive Menu: Winter Warmer"])
    }

    @Test func aDrinkIsListedUnderEveryCategoryItIsIn() {
        #expect(menu([drinkDoc("Mint Mocha", in: ["festive", "hot"])]) == [
            "Festive Menu: Mint Mocha",
            "hot: Mint Mocha",
        ])
    }

    @Test func sectionsRunInCategoryOrderWithUnorderedOnesFirstByName() {
        let drinks = [
            drinkDoc("Iced Latte", in: ["cold"]),
            drinkDoc("Latte", in: ["hot", "popular"]),
            drinkDoc("Mint Mocha", in: ["festive"]),
        ]
        #expect(menu(drinks) == [
            "Festive Menu: Mint Mocha",
            "popular: Latte",
            "hot: Latte",
            "cold: Iced Latte",
        ])
    }

    @Test func drinksAreAlphabeticalWithinASection() {
        let drinks = [drinkDoc("Mocha", in: ["hot"]), drinkDoc("Americano", in: ["hot"]), drinkDoc("Latte", in: ["hot"])]
        #expect(menu(drinks) == ["hot: Americano, Latte, Mocha"])
    }

    @Test func aCategoryWithNoDrinksHasNoSection() {
        #expect(menu([drinkDoc("Latte", in: ["hot"])]) == ["hot: Latte"])
    }

    @Test func aDrinkWhoseCategoryDocumentIsGoneIsUncategorized() {
        #expect(menu([drinkDoc("Mystery", in: ["deleted"])]) == ["Uncategorized: Mystery"])
    }
}
