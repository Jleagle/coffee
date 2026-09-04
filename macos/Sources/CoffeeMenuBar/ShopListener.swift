import Foundation

/// Realtime listener on the coffeeShop/info document — the same Firestore
/// `Listen` RPC the Go CLI uses, carried over Google's WebChannel transport
/// (the transport the Firestore web SDK uses) so we get push updates with no
/// SDK dependency.
///
/// Flow: a handshake POST registers the listen target and returns a session ID,
/// then a long-lived GET (the "backchannel") streams length-prefixed JSON
/// chunks containing ListenResponse messages. When the server closes the
/// backchannel we simply re-handshake, which also re-delivers the current
/// document state, so every reconnect is a free re-sync.
final class ShopListener: @unchecked Sendable {
    private let config: AppConfig
    private let session: SessionStore
    private let urlSession: URLSession
    private var task: Task<Void, Never>?

    /// Called on the main queue with every shop state observed.
    var onState: ((ShopState) -> Void)?

    private static let channelBase = "https://firestore.googleapis.com/google.firestore.v1.Firestore/Listen/channel"

    init(config: AppConfig, session: SessionStore) {
        self.config = config
        self.session = session
        let cfg = URLSessionConfiguration.ephemeral
        // Applies between reads on the streamed backchannel, so a stalled
        // connection fails over to a reconnect. The server pings well within this.
        cfg.timeoutIntervalForRequest = 90
        urlSession = URLSession(configuration: cfg)
    }

    func start() {
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await listenOnce()
                failures = 0
                // Normal server-side close of the backchannel; reconnect quickly.
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                log("listener error (attempt \(failures)): \(error.localizedDescription)")
                if failures >= 3 { emit(.unknown) }
                let delay = UInt64(min(failures * 3, 30))
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }

    private func listenOnce() async throws {
        let token = try await session.freshIDToken(apiKey: config.apiKey)
        let (sid, gsessionid) = try await handshake(token: token)
        try await consumeBackchannel(token: token, sid: sid, gsessionid: gsessionid)
    }

    // MARK: - WebChannel protocol

    private func handshake(token: String) async throws -> (sid: String, gsessionid: String) {
        let listenRequest: [String: Any] = [
            "database": config.database,
            "addTarget": [
                "documents": ["documents": ["\(config.database)/documents/coffeeShop/info"]],
                "targetId": 1,
            ],
        ]
        let reqJSON = String(data: try JSONSerialization.data(withJSONObject: listenRequest), encoding: .utf8)!

        let url = Self.channelBase + "?" + query([
            ("database", config.database),
            ("VER", "8"),
            ("RID", String(Int.random(in: 10000...99999))),
            ("CVER", "22"),
            ("X-HTTP-Session-Id", "gsessionid"),
            ("zx", Self.randomZX()),
            ("t", "1"),
        ])
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = ("count=1&ofs=0&req0___data__=" + Self.encode(reqJSON)).data(using: .utf8)

        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw FirestoreError(message: "webchannel handshake failed: \(snippet)")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        // Body contains: [[0,["c","<SID>",...]]]
        guard let range = body.range(of: "[\"c\",\""),
              let end = body.range(of: "\"", range: range.upperBound..<body.endIndex) else {
            throw FirestoreError(message: "no session id in handshake response")
        }
        let sid = String(body[range.upperBound..<end.lowerBound])
        guard let gsessionid = http.value(forHTTPHeaderField: "x-http-session-id") else {
            throw FirestoreError(message: "no gsessionid in handshake response")
        }
        return (sid, gsessionid)
    }

    private func consumeBackchannel(token: String, sid: String, gsessionid: String) async throws {
        let url = Self.channelBase + "?" + query([
            ("database", config.database),
            ("gsessionid", gsessionid),
            ("VER", "8"),
            ("RID", "rpc"),
            ("SID", sid),
            ("AID", "0"),
            ("CI", "0"),
            ("TYPE", "xmlhttp"),
            ("zx", Self.randomZX()),
            ("t", "1"),
        ])
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (bytes, resp) = try await urlSession.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw FirestoreError(message: "backchannel returned \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        var parser = ChunkParser()
        for try await byte in bytes {
            for chunk in try parser.append(byte) {
                try process(chunk: chunk)
            }
        }
    }

    private func process(chunk: String) throws {
        guard let data = chunk.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw FirestoreError(message: "unparseable webchannel chunk")
        }
        for entry in entries {
            guard entry.count >= 2, let payload = entry[1] as? [Any] else { continue }
            if let control = payload.first as? String {
                if control == "stop" {
                    throw FirestoreError(message: "server requested reconnect")
                }
                continue // "noop" keep-alives etc.
            }
            for message in payload {
                guard let msg = message as? [String: Any] else { continue }
                if let change = msg["documentChange"] as? [String: Any],
                   let doc = change["document"] as? [String: Any],
                   let fields = doc["fields"] as? [String: Any],
                   let open = FS.bool(fields, "open") {
                    emit(open ? .open : .closed)
                }
            }
        }
    }

    private func emit(_ state: ShopState) {
        DispatchQueue.main.async { [onState] in onState?(state) }
    }

    // MARK: - Helpers

    private func query(_ items: [(String, String)]) -> String {
        items.map { "\($0.0)=\(Self.encode($0.1))" }.joined(separator: "&")
    }

    private static let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func randomZX() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<12).map { _ in chars.randomElement()! })
    }
}

/// Splits the backchannel byte stream into WebChannel frames. Each frame is a
/// decimal length (in UTF-16 code units), a newline, then that many characters
/// of JSON.
struct ChunkParser {
    private var buf = Data()

    mutating func append(_ byte: UInt8) throws -> [String] {
        buf.append(byte)
        var out: [String] = []
        while let chunk = try extract() {
            out.append(chunk)
        }
        return out
    }

    private mutating func extract() throws -> String? {
        guard let nl = buf.firstIndex(of: 0x0A) else { return nil }
        let lenOffset = buf.distance(from: buf.startIndex, to: nl)
        guard let lenStr = String(data: buf.prefix(lenOffset), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let length = Int(lenStr), length >= 0, length < 10_000_000 else {
            throw FirestoreError(message: "bad webchannel frame length")
        }

        // Decode the maximal valid UTF-8 prefix of the rest (the tail may end
        // mid-character while the stream is still arriving).
        var rest = Data(buf.dropFirst(lenOffset + 1))
        var decoded = String(data: rest, encoding: .utf8)
        var stripped = 0
        while decoded == nil && stripped < 3 && !rest.isEmpty {
            rest.removeLast()
            stripped += 1
            decoded = String(data: rest, encoding: .utf8)
        }
        guard let text = decoded else {
            throw FirestoreError(message: "invalid utf-8 in webchannel frame")
        }
        guard text.utf16.count >= length else { return nil } // need more bytes

        let chunk = String(decoding: Array(text.utf16.prefix(length)), as: UTF16.self)
        buf = Data(buf.dropFirst(lenOffset + 1 + chunk.utf8.count))
        return chunk
    }
}
