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

/// Persists the session (tokens, identity, recent orders) in the app's
/// UserDefaults (~/Library/Preferences).
actor SessionStore {
    private let defaults = UserDefaults.standard

    /// False until the browser sign-in flow has written tokens.
    var hasSession: Bool {
        value("id_token") != nil && value("refresh_token") != nil && value("uid") != nil
    }

    /// Writes the session produced by the browser sign-in flow.
    func applyLogin(_ creds: LoginCredentials) {
        defaults.set(creds.idToken, forKey: "id_token")
        defaults.set(creds.refreshToken, forKey: "refresh_token")
        defaults.set(creds.uid, forKey: "uid")
        defaults.set(creds.email, forKey: "email")
        defaults.set(creds.displayName, forKey: "display_name")
    }

    func value(_ key: String) -> String? {
        defaults.string(forKey: key)
    }

    func info() -> SessionInfo {
        SessionInfo(
            uid: value("uid") ?? "",
            email: value("email") ?? "",
            displayName: value("display_name") ?? ""
        )
    }

    /// The most recent orders, newest first (max 5).
    func recentOrders() -> [LastOrder] {
        guard let data = defaults.data(forKey: "recent_orders"),
              let orders = try? JSONDecoder().decode([LastOrder].self, from: data) else { return [] }
        return Array(orders.prefix(5))
    }

    /// Puts the order at the front of the recents (replacing any entry with
    /// the same drink/shots/options) and keeps at most 5.
    func saveRecentOrder(_ order: LastOrder) {
        var orders = recentOrders().filter { !$0.sameSelection(as: order) }
        orders.insert(order, at: 0)
        if let data = try? JSONEncoder().encode(Array(orders.prefix(5))) {
            defaults.set(data, forKey: "recent_orders")
        }
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
        defaults.set(idToken, forKey: "id_token")
        if let newRefresh = obj["refresh_token"] as? String {
            defaults.set(newRefresh, forKey: "refresh_token")
        }
        return idToken
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
