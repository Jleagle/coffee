import Foundation

struct SessionInfo: Sendable {
    let uid: String
    let email: String
    let displayName: String
}

enum SessionError: LocalizedError {
    case invalid(String)
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let msg):
            return msg
        case .refreshFailed(let msg):
            return "Token refresh failed: \(msg)"
        }
    }
}

/// Reads and writes ~/.coffee.json — the same file the Go CLI uses.
/// Unknown keys are preserved on every write.
actor SessionStore {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".coffee.json")

    private var dict: [String: Any]

    init() throws {
        let url = Self.fileURL
        guard let data = try? Data(contentsOf: url) else {
            dict = [:] // no file yet — the browser sign-in flow will create it
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionError.invalid("Could not parse \(url.path)")
        }
        dict = obj
    }

    /// False until the browser sign-in flow (or the CLI's set-token) has
    /// written tokens.
    var hasSession: Bool {
        value("id_token") != nil && value("refresh_token") != nil && value("uid") != nil
    }

    /// Writes the session produced by the browser sign-in flow.
    func applyLogin(_ creds: LoginCredentials) {
        dict["id_token"] = creds.idToken
        dict["refresh_token"] = creds.refreshToken
        dict["uid"] = creds.uid
        dict["email"] = creds.email
        dict["display_name"] = creds.displayName
        do {
            try save()
        } catch {
            log("could not save session: \(error.localizedDescription)")
        }
    }

    func value(_ key: String) -> String? {
        dict[key] as? String
    }

    func info() -> SessionInfo {
        SessionInfo(
            uid: value("uid") ?? "",
            email: value("email") ?? "",
            displayName: value("display_name") ?? ""
        )
    }

    /// The most recent orders, newest first (max 5). Seeds itself from a
    /// legacy single "last_order" entry when "recent_orders" hasn't been
    /// written yet.
    func recentOrders() -> [LastOrder] {
        if let arr = dict["recent_orders"] as? [Any] {
            return Array(arr.compactMap(Self.decodeOrder).prefix(5))
        }
        guard let obj = dict["last_order"], let last = Self.decodeOrder(obj) else { return [] }
        return [last]
    }

    /// Puts the order at the front of "recent_orders" (replacing any entry with
    /// the same drink/shots/options) and keeps at most 5.
    func saveRecentOrder(_ order: LastOrder) {
        var orders = recentOrders().filter { !$0.sameSelection(as: order) }
        orders.insert(order, at: 0)
        dict["recent_orders"] = orders.prefix(5).compactMap(Self.encodeOrder)
        dict.removeValue(forKey: "last_order") // legacy key, superseded by recent_orders
        try? save()
    }

    private static func decodeOrder(_ obj: Any) -> LastOrder? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(LastOrder.self, from: data)
    }

    private static func encodeOrder(_ order: LastOrder) -> Any? {
        guard let data = try? JSONEncoder().encode(order) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Tokens

    func freshIDToken(apiKey: String) async throws -> String {
        if let token = value("id_token"), let exp = Self.jwtExpiry(token), exp.timeIntervalSinceNow > 120 {
            return token
        }
        return try await refresh(apiKey: apiKey)
    }

    func refresh(apiKey: String) async throws -> String {
        guard let refreshToken = value("refresh_token") else {
            throw SessionError.invalid("No refresh_token in session")
        }
        var req = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=refresh_token&refresh_token=\(refreshToken)".data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw SessionError.refreshFailed(snippet)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = obj["id_token"] as? String else {
            throw SessionError.refreshFailed("no id_token in response")
        }
        dict["id_token"] = idToken
        if let newRefresh = obj["refresh_token"] as? String {
            dict["refresh_token"] = newRefresh
        }
        try? save()
        return idToken
    }

    private func save() throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
