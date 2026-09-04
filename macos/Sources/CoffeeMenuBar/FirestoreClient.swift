import Foundation

struct FirestoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal Firestore REST client authenticated with the session's ID token.
final class FirestoreClient: @unchecked Sendable {
    let config: AppConfig
    let session: SessionStore
    private let urlSession: URLSession

    init(config: AppConfig, session: SessionStore) {
        self.config = config
        self.session = session
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: cfg)
    }

    var documentsBase: String {
        "https://firestore.googleapis.com/v1/\(config.database)/documents"
    }

    private func send(method: String, url: String, body: [String: Any]? = nil, forceRefresh: Bool = false) async throws -> Data {
        let token = forceRefresh
            ? try await session.refresh(apiKey: config.apiKey)
            : try await session.freshIDToken(apiKey: config.apiKey)

        guard let u = URL(string: url) else {
            throw FirestoreError(message: "bad url: \(url)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, resp) = try await urlSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if (status == 401 || status == 403) && !forceRefresh {
            return try await send(method: method, url: url, body: body, forceRefresh: true)
        }
        guard (200..<300).contains(status) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw FirestoreError(message: "Firestore returned \(status): \(snippet)")
        }
        return data
    }

    func listCollection(_ collection: String, fieldMask: [String] = []) async throws -> [(id: String, fields: [String: Any])] {
        var out: [(id: String, fields: [String: Any])] = []
        var pageToken: String?
        repeat {
            var url = "\(documentsBase)/\(collection)?pageSize=300"
            for f in fieldMask { url += "&mask.fieldPaths=\(f)" }
            if let t = pageToken, let enc = t.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                url += "&pageToken=\(enc)"
            }
            let data = try await send(method: "GET", url: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FirestoreError(message: "unexpected list response for \(collection)")
            }
            for doc in obj["documents"] as? [[String: Any]] ?? [] {
                guard let name = doc["name"] as? String else { continue }
                out.append((FS.lastPathComponent(name), doc["fields"] as? [String: Any] ?? [:]))
            }
            pageToken = obj["nextPageToken"] as? String
        } while pageToken != nil
        return out
    }

    /// Returns the matched documents (rows without a "document" key are skipped).
    func runQuery(_ structuredQuery: [String: Any]) async throws -> [[String: Any]] {
        let data = try await send(method: "POST", url: "\(documentsBase):runQuery", body: ["structuredQuery": structuredQuery])
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FirestoreError(message: "unexpected query response")
        }
        return rows.compactMap { $0["document"] as? [String: Any] }
    }

    func createDocument(collection: String, fields: [String: Any]) async throws {
        _ = try await send(method: "POST", url: "\(documentsBase)/\(collection)", body: ["fields": fields])
    }
}

/// Helpers for Firestore's REST value encoding ({"stringValue": ...} etc).
enum FS {
    // MARK: encode
    static func s(_ v: String) -> [String: Any] { ["stringValue": v] }
    static func i(_ v: Int64) -> [String: Any] { ["integerValue": String(v)] }
    static func ref(_ v: String) -> [String: Any] { ["referenceValue": v] }
    static func arr(_ v: [[String: Any]]) -> [String: Any] { ["arrayValue": ["values": v]] }
    static func map(_ v: [String: Any]) -> [String: Any] { ["mapValue": ["fields": v]] }

    // MARK: decode
    static func string(_ fields: [String: Any], _ key: String) -> String? {
        (fields[key] as? [String: Any])?["stringValue"] as? String
    }

    static func int(_ fields: [String: Any], _ key: String) -> Int64? {
        guard let v = (fields[key] as? [String: Any])?["integerValue"] else { return nil }
        if let s = v as? String { return Int64(s) }
        if let n = v as? NSNumber { return n.int64Value }
        return nil
    }

    static func bool(_ fields: [String: Any], _ key: String) -> Bool? {
        (fields[key] as? [String: Any])?["booleanValue"] as? Bool
    }

    static func stringArray(_ fields: [String: Any], _ key: String) -> [String] {
        arrayValues(fields, key).compactMap { $0["stringValue"] as? String }
    }

    static func refArray(_ fields: [String: Any], _ key: String) -> [String] {
        arrayValues(fields, key).compactMap { v in
            (v["referenceValue"] as? String).map(lastPathComponent)
        }
    }

    static func mapFields(_ fields: [String: Any], _ key: String) -> [String: Any] {
        ((fields[key] as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any] ?? [:]
    }

    static func lastPathComponent(_ ref: String) -> String {
        String(ref.split(separator: "/").last ?? "")
    }

    private static func arrayValues(_ fields: [String: Any], _ key: String) -> [[String: Any]] {
        ((fields[key] as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [[String: Any]] ?? []
    }
}
