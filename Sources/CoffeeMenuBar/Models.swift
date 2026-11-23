import Foundation

enum ShopState {
    case unknown, open, closed
}

struct AppConfig: Sendable {
    let projectID: String
    let apiKey: String
    var database: String { "projects/\(projectID)/databases/(default)" }

    // Public Firebase web config — the same values ship in every web client, so
    // it's safe to embed. Used as a fallback so a fresh install can still
    // reach the sign-in flow with no other setup.
    static let defaultProjectID = "protected-jbi-firebase"
    static let defaultAPIKey = "AIzaSyBKSStxYeu_ALi1tm6Fjfu4aW9RFu9PNNk"
}

// Option collections, in display order.
let optionCollections: [(coll: String, title: String)] = [
    ("beans", "Beans"),
    ("milks", "Milk"),
    ("cup_choices", "Cup"),
    ("syrups", "Syrup"),
    ("sugars", "Sugar"),
    ("toppings", "Topping"),
    ("extras", "Extra"),
]

struct DrinkCategory: Sendable {
    let id: String
    let name: String
    let order: Int
}

struct Drink: Sendable {
    let id: String
    let name: String
    let categoryIDs: [String]
    let optionGroups: Set<String>
    let requiredOptions: Set<String>
    let defaultOptionIDs: [String: String] // collection -> option doc ID
}

struct OptionItem: Sendable {
    let id: String
    let name: String
}

struct SelectedOption: Sendable {
    let collection: String
    let id: String
    let name: String
    let count: Int
}

/// A heading in the drink menu and the drinks listed under it.
struct DrinkSection: Sendable {
    let name: String
    let drinks: [Drink]
}

struct Catalog: Sendable {
    let drinks: [Drink]
    let categories: [String: DrinkCategory]
    let options: [String: [OptionItem]]
}

extension Catalog {
    /// Builds the catalog from the documents of the drinks and
    /// drinkCategories collections.
    init(
        drinkDocs: [(id: String, fields: [String: Any])],
        categoryDocs: [(id: String, fields: [String: Any])],
        options: [String: [OptionItem]]
    ) {
        // A category without an order sorts first, as in the web app.
        let categories = Dictionary(uniqueKeysWithValues: categoryDocs.map { doc in
            (doc.id, DrinkCategory(
                id: doc.id,
                name: FS.string(doc.fields, "name") ?? "",
                order: Int(FS.int(doc.fields, "order") ?? 0)
            ))
        })

        var drinks: [Drink] = []
        for doc in drinkDocs {
            guard let name = FS.string(doc.fields, "name") else { continue }

            var defaults: [String: String] = [:]
            for (coll, value) in FS.mapFields(doc.fields, "defaultOptions") {
                if let ref = (value as? [String: Any])?["referenceValue"] as? String {
                    defaults[coll] = FS.lastPathComponent(ref)
                }
            }
            drinks.append(Drink(
                id: doc.id,
                name: name,
                categoryIDs: FS.refArray(doc.fields, "category"),
                optionGroups: Set(FS.mapFields(doc.fields, "optionGroups").keys),
                requiredOptions: Set(FS.stringArray(doc.fields, "requiredOptions")),
                defaultOptionIDs: defaults
            ))
        }

        self.init(drinks: drinks, categories: categories, options: options)
    }

    /// The drink menu laid out as the web app does: a section per category,
    /// each drink listed under every category it is in. Sections run in
    /// category order then by name, drinks alphabetically within a section.
    /// A drink whose category document is gone goes under "Uncategorized".
    var sections: [DrinkSection] {
        var byName: [String: (order: Int, drinks: [Drink])] = [:]
        for drink in drinks {
            for id in drink.categoryIDs {
                let category = categories[id]
                byName[category?.name ?? "Uncategorized", default: (category?.order ?? 0, [])].drinks.append(drink)
            }
        }
        return byName
            .sorted { a, b in
                if a.value.order != b.value.order { return a.value.order < b.value.order }
                return a.key.localizedCaseInsensitiveCompare(b.key) == .orderedAscending
            }
            .map { DrinkSection(name: $0.key, drinks: $0.value.drinks.sorted { $0.name < $1.name }) }
    }
}

// Stored under "recent_orders" (newest first, max 5) in UserDefaults.
struct LastOrder: Codable, Sendable {
    var drinkID: String
    var drinkName: String
    var shots: Int
    var options: [LastOrderOption]
    var placedAt: String?

    enum CodingKeys: String, CodingKey {
        case drinkID = "drink_id"
        case drinkName = "drink_name"
        case shots
        case options
        case placedAt = "placed_at"
    }

    var summary: String {
        var s = drinkName
        if shots == 2 { s += " (Double)" }
        if shots == 3 { s += " (Triple)" }
        return s
    }

    var optionsSummary: String {
        options.map { opt in
            let count = opt.count ?? 1
            return count > 1 ? "\(opt.name) ×\(count)" : opt.name
        }.joined(separator: ", ")
    }

    /// True when the other order is the same drink, shots and options — used to
    /// dedupe the recent-orders list (a repeat order moves to the front).
    func sameSelection(as other: LastOrder) -> Bool {
        guard drinkID == other.drinkID, shots == other.shots, options.count == other.options.count else { return false }
        return zip(options, other.options).allSatisfy {
            $0.collection == $1.collection && $0.id == $1.id && ($0.count ?? 1) == ($1.count ?? 1)
        }
    }
}

struct LastOrderOption: Codable, Sendable {
    var collection: String
    var id: String
    var name: String
    var count: Int?
}
