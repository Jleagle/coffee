import Foundation
import Network

/// Everything needed to store a session after a browser sign-in.
struct LoginCredentials: Sendable {
    let idToken: String
    let refreshToken: String
    let uid: String
    let email: String
    let displayName: String
}

/// A one-shot loopback HTTP server backing the browser sign-in flow.
///
/// `localhost` is an authorized domain on the Firebase project, so a page
/// served from here can run the official Firebase JS `signInWithPopup(Google)`
/// flow with just the web API key — no OAuth client registration needed. The
/// page posts the resulting ID + refresh tokens back, we verify them with
/// accounts:lookup (same as the CLI's set-token), and hand the validated
/// session to `onCredentials`.
final class LoginServer: @unchecked Sendable {
    private let config: AppConfig
    private let loginHint: String
    // Per-launch URL token: only the page this app opened knows where to post,
    // so other local processes / web pages can't inject a session.
    private let secret = UUID().uuidString
    private var listener: NWListener?
    private var delivered = false
    private let queue = DispatchQueue(label: "coffee.login-server")

    /// Called once with verified credentials. May fire on any thread.
    var onCredentials: ((LoginCredentials) -> Void)?

    init(config: AppConfig, loginHint: String?) {
        self.config = config
        // Injected into the page's JS, so keep it to safe email characters.
        self.loginHint = (loginHint ?? "").filter { $0.isLetter || $0.isNumber || "@._+-".contains($0) }
    }

    /// Starts listening on a random loopback port and returns the sign-in page
    /// URL. The host must be `localhost` (not 127.0.0.1) — Firebase checks the
    /// page origin against the project's authorized domains.
    func start() async throws -> URL {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Clearing the handler on first resolution keeps the continuation
            // single-shot (state events arrive serially on `queue`).
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let error), .waiting(let error):
                    listener?.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                case .cancelled:
                    listener?.stateUpdateHandler = nil
                    cont.resume(throwing: SessionError.invalid("Sign-in server cancelled"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        guard let port = listener.port else {
            throw SessionError.invalid("Sign-in server has no port")
        }
        return URL(string: "http://localhost:\(port.rawValue)/\(secret)/")!
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return conn.cancel() }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil || buf.count > 1_000_000 { return conn.cancel() }
            if let request = Self.parseRequest(buf) {
                self.route(request, conn)
            } else if complete {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func route(_ request: (method: String, path: String, body: Data), _ conn: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/\(secret)/"):
            respond(conn, status: "200 OK", type: "text/html; charset=utf-8", body: page())
        case ("POST", "/\(secret)/session"):
            guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let idToken = obj["id_token"] as? String,
                  let refreshToken = obj["refresh_token"] as? String else {
                return respond(conn, status: "400 Bad Request", type: "text/plain", body: "missing tokens")
            }
            Task {
                do {
                    let creds = try await self.verify(idToken: idToken, refreshToken: refreshToken)
                    self.queue.async {
                        // First completed sign-in wins (e.g. the page was opened twice).
                        guard !self.delivered else {
                            return self.respond(conn, status: "200 OK", type: "text/plain", body: "already signed in")
                        }
                        self.delivered = true
                        self.respond(conn, status: "200 OK", type: "text/plain", body: "ok")
                        self.onCredentials?(creds)
                    }
                } catch {
                    log("sign-in verification failed: \(error.localizedDescription)")
                    self.respond(conn, status: "502 Bad Gateway", type: "text/plain", body: error.localizedDescription)
                }
            }
        default:
            respond(conn, status: "404 Not Found", type: "text/plain", body: "not found")
        }
    }

    private func respond(_ conn: NWConnection, status: String, type: String, body: String) {
        let data = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Returns (method, path, body) once the request — including its full body,
    /// per Content-Length — has arrived; nil while incomplete or unparseable.
    private static func parseRequest(_ data: Data) -> (method: String, path: String, body: Data)? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return (String(parts[0]), String(parts[1]), Data(body.prefix(contentLength)))
    }

    // MARK: - Verification

    /// Confirms the tokens with accounts:lookup and returns the canonical
    /// uid/email/name — mirrors the Go CLI's set-token.
    private func verify(idToken: String, refreshToken: String) async throws -> LoginCredentials {
        var req = URLRequest(url: URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=\(config.apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["idToken": idToken])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = (obj["users"] as? [[String: Any]])?.first,
              let uid = user["localId"] as? String else {
            throw SessionError.invalid("Could not verify the signed-in account")
        }
        return LoginCredentials(
            idToken: idToken,
            refreshToken: refreshToken,
            uid: uid,
            email: user["email"] as? String ?? "",
            displayName: user["displayName"] as? String ?? ""
        )
    }

    // MARK: - Page

    private func page() -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>Coffee — Sign in</title>
        <style>
          body { font: 15px -apple-system, system-ui, sans-serif; display: flex; flex-direction: column;
                 align-items: center; justify-content: center; min-height: 90vh; gap: 16px;
                 background: #f5f2ee; color: #333; }
          @media (prefers-color-scheme: dark) { body { background: #1e1c1a; color: #ddd; } }
          h1 { font-size: 22px; margin: 0; }
          button { font: inherit; padding: 10px 24px; border-radius: 8px; border: 1px solid #b58b5a;
                   background: #8b5a2b; color: white; cursor: pointer; }
          button:disabled { opacity: 0.5; cursor: default; }
          #status { max-width: 32em; text-align: center; }
        </style>
        </head>
        <body>
        <h1>☕ Coffee</h1>
        <p id="status">Sign in with Google so the menu bar app can order coffee as you.</p>
        <button id="btn">Sign in with Google</button>
        <script src="https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js"></script>
        <script src="https://www.gstatic.com/firebasejs/10.14.1/firebase-auth-compat.js"></script>
        <script>
        firebase.initializeApp({ apiKey: "\(config.apiKey)", authDomain: "\(config.projectID).firebaseapp.com" });
        // Keep the session out of the browser's storage — the app owns it.
        firebase.auth().setPersistence(firebase.auth.Auth.Persistence.NONE);
        var btn = document.getElementById('btn');
        // Not named "status": a top-level `var status` is window.status, which
        // stringifies whatever is assigned to it.
        var msg = document.getElementById('status');
        // A popup (not signInWithRedirect) because the page is served from
        // localhost while the Firebase auth handler lives on firebaseapp.com:
        // browsers block the third-party storage a redirect needs to carry its
        // state back, so a redirect loops forever. The popup returns its result
        // via postMessage instead, but that requires a user gesture — hence the
        // button; it can't be auto-triggered without being popup-blocked.
        btn.onclick = async function () {
          btn.disabled = true;
          msg.textContent = 'Waiting for Google\\u2026';
          try {
            var provider = new firebase.auth.GoogleAuthProvider();
            var hint = "\(loginHint)";
            if (hint) provider.setCustomParameters({ login_hint: hint });
            var result = await firebase.auth().signInWithPopup(provider);
            msg.textContent = 'Handing the session to the app\\u2026';
            var resp = await fetch('/\(secret)/session', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                id_token: await result.user.getIdToken(),
                refresh_token: result.user.refreshToken
              })
            });
            if (!resp.ok) throw new Error(await resp.text());
            msg.textContent = 'Signed in as ' + (result.user.email || result.user.uid) + ' \\u2014 you can close this tab.';
            btn.remove();
          } catch (e) {
            msg.textContent = 'Sign-in failed: ' + (e && e.message ? e.message : e);
            btn.disabled = false;
          }
        };
        </script>
        </body>
        </html>
        """
    }
}
