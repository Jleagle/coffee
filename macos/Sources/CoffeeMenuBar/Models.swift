import Foundation

enum ShopState {
    case unknown, open, closed
}

struct AppConfig: Sendable {
    let projectID: String
    let apiKey: String
    var database: String { "projects/\(projectID)/databases/(default)" }

    // Public Firebase web config — the same values ship in every web client, so
    // it's safe to embed. Used as a fallback so a fresh install (no env vars,
    // no CLI-written ~/.coffee.json) can still reach the sign-in flow.
    static let defaultProjectID = "protected-jbi-firebase"
    static let defaultAPIKey = "AIzaSyBKSStxYeu_ALi1tm6Fjfu4aW9RFu9PNNk"
}

// Mirrors firebase.OptionCollections in the Go CLI, in display order.
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
    let categoryID: String
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

struct Catalog: Sendable {
    let drinks: [Drink]
    let categories: [String: DrinkCategory]
    let options: [String: [OptionItem]]
}

// Stored under "recent_orders" (newest first, max 5) in ~/.coffee.json,
// shared with the Go CLI's session file.
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
