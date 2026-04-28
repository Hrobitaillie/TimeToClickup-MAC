import Foundation
import Network

/// Tiny HTTP server bound to a random localhost port. Used during the
/// Google OAuth flow to receive the redirect back from the browser
/// (`http://127.0.0.1:PORT/?code=…`).
@MainActor
final class LocalLoopbackServer {
    private var listener: NWListener?
    private var codeContinuation: CheckedContinuation<String, Error>?

    /// Starts listening; resolves with the bound port number.
    func start() async throws -> Int {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue {
                        resumed = true
                        cont.resume(returning: Int(p))
                    }
                case .failed(let err):
                    resumed = true
                    cont.resume(throwing: err)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in
                    self?.accept(conn)
                }
            }
            listener.start(queue: .main)
        }
    }

    /// Resolves with the OAuth code once the browser hits the redirect.
    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            self.codeContinuation = cont
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let cont = codeContinuation {
            cont.resume(throwing: CancellationError())
            codeContinuation = nil
        }
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let data, let raw = String(data: data, encoding: .utf8) else {
                    self.respondError(connection, msg: "Bad request")
                    return
                }
                self.parse(raw, connection: connection)
            }
        }
    }

    private func parse(_ raw: String, connection: NWConnection) {
        // Request line: "GET /path?query HTTP/1.1"
        let firstLine = raw.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            respondError(connection, msg: "Malformed request line")
            return
        }
        let path = parts[1]
        guard let url = URL(string: "http://127.0.0.1\(path)"),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            respondError(connection, msg: "Invalid request URL")
            return
        }

        let items = comps.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value {
            respondSuccess(connection)
            codeContinuation?.resume(returning: code)
            codeContinuation = nil
        } else if let err = items.first(where: { $0.name == "error" })?.value {
            respondError(connection, msg: "OAuth error: \(err)")
            codeContinuation?.resume(
                throwing: GoogleAuthService.AuthError.deniedByUser(err)
            )
            codeContinuation = nil
        } else {
            respondError(connection, msg: "Missing code parameter")
        }
    }

    // MARK: - Responses

    private func respondSuccess(_ conn: NWConnection) {
        let body = """
        <!doctype html><html lang="fr"><head><meta charset="utf-8">
        <title>TimeToClickup connecté</title><style>
        :root{color-scheme:light dark}
        body{font-family:-apple-system,'SF Pro Display',system-ui,sans-serif;
        background:#f5f5f7;color:#1d1d1f;display:flex;align-items:center;
        justify-content:center;height:100vh;margin:0}
        @media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#f2f2f7}
        .card{background:#2c2c2e;box-shadow:none;border:1px solid #3a3a3c}}
        .card{background:white;border-radius:14px;padding:48px 56px;text-align:center;
        box-shadow:0 10px 32px rgba(0,0,0,0.08);max-width:420px}
        h1{font-size:20px;font-weight:600;margin:0 0 8px}
        p{font-size:13px;color:#86868b;margin:0;line-height:1.5}
        .check{font-size:38px;color:#34c759;margin-bottom:8px}
        </style></head><body><div class="card">
        <div class="check">✓</div>
        <h1>TimeToClickup connecté à Google Calendar</h1>
        <p>Tu peux fermer cet onglet et revenir à l'app.</p>
        </div></body></html>
        """
        send(conn, status: "200 OK", body: body)
    }

    private func respondError(_ conn: NWConnection, msg: String) {
        let safe = msg.replacingOccurrences(of: "<", with: "&lt;")
        let body = """
        <!doctype html><html><body style="font-family:system-ui;padding:40px">
        <h2>Erreur OAuth</h2><pre>\(safe)</pre>
        </body></html>
        """
        send(conn, status: "400 Bad Request", body: body)
    }

    private func send(_ conn: NWConnection, status: String, body: String) {
        let bytes = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n" +
                     "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(bytes)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
