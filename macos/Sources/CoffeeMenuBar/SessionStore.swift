import Foundation

struct SessionInfo: Sendable {
    let uid: String
    let email: String
    let displayName: String
}

enum SessionError: LocalizedError {
    case missingFile(String)
    case invalid(String)
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path):
            return "No session at \(path) — run `coffee set-token --token <refresh-token>` first"
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
            throw SessionError.missingFile(url.path)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionError.invalid("Could not parse \(url.path)")
        }
        dict = obj
        guard dict["id_token"] is String, dict["refresh_token"] is String, dict["uid"] is String else {
            throw SessionError.invalid("Incomplete session in \(url.path) — run `coffee set-token` first")
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

    /// Persists project ID / API key so the app works when launched outside a
    /// shell (Finder, brew services) where the env vars aren't set.
    func setConfigIfMissing(projectID: String, apiKey: String) {
        var changed = false
        if value("project_id") == nil { dict["project_id"] = projectID; changed = true }
        if value("api_key") == nil { dict["api_key"] = apiKey; changed = true }
        if changed { try? save() }
    }

    func lastOrder() -> LastOrder? {
        guard let obj = dict["last_order"],
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(LastOrder.self, from: data)
    }

    func saveLastOrder(_ order: LastOrder) {
        guard let data = try? JSONEncoder().encode(order),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        dict["last_order"] = obj
        try? save()
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
