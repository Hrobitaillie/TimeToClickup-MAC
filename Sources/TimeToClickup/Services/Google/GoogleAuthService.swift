import Foundation
import AppKit
import CryptoKit
import Combine

/// Manages Google OAuth 2.0 (PKCE flow) for desktop apps.
/// Tokens persist in `UserDefaults`; access tokens are refreshed on
/// demand using the long-lived refresh token.
@MainActor
final class GoogleAuthService: ObservableObject {
    static let shared = GoogleAuthService()

    @Published private(set) var connectedEmail: String?
    @Published private(set) var isAuthorizing = false
    @Published var lastError: String?

    private var inflightServer: LocalLoopbackServer?

    private let clientIdKey      = "google_client_id"
    private let clientSecretKey  = "google_client_secret"
    private let accessTokenKey   = "google_access_token"
    private let refreshTokenKey  = "google_refresh_token"
    private let expiryKey        = "google_token_expiry"
    private let emailKey         = "google_email"

    private static let scopes = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/userinfo.email"
    ]

    /// Resolves to the bundled client_id (shipped with the app) when
    /// available, falling back to a user-entered override stored in
    /// UserDefaults. Same logic for `clientSecret`.
    var clientId: String? {
        AppCredentials.googleClientId
            ?? UserDefaults.standard.string(forKey: clientIdKey)
    }
    var clientSecret: String? {
        AppCredentials.googleClientSecret
            ?? UserDefaults.standard.string(forKey: clientSecretKey)
    }
    var hasCredentials: Bool {
        !(clientId ?? "").isEmpty && !(clientSecret ?? "").isEmpty
    }
    var hasBundledCredentials: Bool {
        AppCredentials.hasBundledGoogleCredentials
    }
    var isConnected: Bool { connectedEmail != nil }

    private init() {
        connectedEmail = UserDefaults.standard.string(forKey: emailKey)
    }

    // MARK: - Credentials & lifecycle

    func setCredentials(clientId: String, clientSecret: String) {
        UserDefaults.standard.set(
            clientId.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: clientIdKey
        )
        UserDefaults.standard.set(
            clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: clientSecretKey
        )
    }

    func disconnect() {
        for k in [accessTokenKey, refreshTokenKey, expiryKey, emailKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        connectedEmail = nil
        LogStore.shared.info("Google déconnecté")
    }

    /// Aborts an in-flight OAuth flow (closes the local server, makes
    /// the awaiting `connect()` throw). Lets the user retry without
    /// waiting for the 3-min timeout.
    func cancelAuthorization() {
        guard isAuthorizing else { return }
        inflightServer?.stop()
        inflightServer = nil
        isAuthorizing = false
        LogStore.shared.info("Google: autorisation annulée")
    }

    /// Runs the full OAuth flow: opens the browser, catches the
    /// redirect on a localhost port, exchanges the code for tokens,
    /// fetches the user email.
    func connect() async throws {
        // Any previous flow gets cancelled — lets the user retry after
        // closing a stale browser window.
        if isAuthorizing { cancelAuthorization() }

        guard let cid = clientId, !cid.isEmpty,
              let secret = clientSecret, !secret.isEmpty else {
            throw AuthError.missingCredentials
        }

        isAuthorizing = true
        defer {
            isAuthorizing = false
            inflightServer = nil
        }

        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.sha256Base64URL(codeVerifier)

        let server = LocalLoopbackServer()
        inflightServer = server
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var components = URLComponents(
            string: "https://accounts.google.com/o/oauth2/v2/auth"
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: cid),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let authURL = components.url else { throw AuthError.invalidURL }

        LogStore.shared.info("Google: ouverture du navigateur (port \(port))")
        NSWorkspace.shared.open(authURL)

        let code: String
        do {
            code = try await Self.withTimeout(seconds: 180) {
                try await server.waitForCode()
            }
        } catch {
            server.stop()
            LogStore.shared.error("Google auth: \(error.localizedDescription)")
            throw error
        }
        server.stop()

        let tokens = try await exchangeCodeForTokens(
            code: code, verifier: codeVerifier, redirectURI: redirectURI,
            clientId: cid, clientSecret: secret
        )
        saveTokens(tokens)

        let email = (try? await fetchUserEmail(token: tokens.accessToken)) ?? "Google"
        UserDefaults.standard.set(email, forKey: emailKey)
        connectedEmail = email
        LogStore.shared.info("✓ Google connecté : \(email)")
    }

    /// Returns a valid access token, refreshing transparently when the
    /// stored one is about to expire.
    func accessToken() async throws -> String {
        let stored = UserDefaults.standard.string(forKey: accessTokenKey) ?? ""
        let expiry = UserDefaults.standard.double(forKey: expiryKey)
        if !stored.isEmpty, Date().timeIntervalSince1970 < expiry - 60 {
            return stored
        }
        guard let refresh = UserDefaults.standard.string(forKey: refreshTokenKey),
              !refresh.isEmpty,
              let cid = clientId, let secret = clientSecret else {
            throw AuthError.notConnected
        }
        let tokens = try await refreshAccessToken(
            refresh: refresh, clientId: cid, clientSecret: secret
        )
        saveTokens(tokens, keepingRefresh: refresh)
        return tokens.accessToken
    }

    // MARK: - Token plumbing

    private func saveTokens(_ tokens: TokenResponse,
                            keepingRefresh existing: String? = nil) {
        UserDefaults.standard.set(tokens.accessToken, forKey: accessTokenKey)
        if let r = tokens.refreshToken {
            UserDefaults.standard.set(r, forKey: refreshTokenKey)
        } else if let existing {
            UserDefaults.standard.set(existing, forKey: refreshTokenKey)
        }
        let expiry = Date()
            .addingTimeInterval(TimeInterval(tokens.expiresIn))
            .timeIntervalSince1970
        UserDefaults.standard.set(expiry, forKey: expiryKey)
    }

    private func exchangeCodeForTokens(
        code: String, verifier: String, redirectURI: String,
        clientId: String, clientSecret: String
    ) async throws -> TokenResponse {
        try await tokenRequest(body: [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ])
    }

    private func refreshAccessToken(
        refresh: String, clientId: String, clientSecret: String
    ) async throws -> TokenResponse {
        try await tokenRequest(body: [
            "refresh_token": refresh,
            "client_id": clientId,
            "client_secret": clientSecret,
            "grant_type": "refresh_token"
        ])
    }

    private func tokenRequest(body: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = body
            .map { "\($0.key)=\($0.value.urlEncoded)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.tokenRequestFailed(String(body.prefix(200)))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchUserEmail(token: String) async throws -> String {
        var req = URLRequest(
            url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
        )
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        struct UserInfo: Decodable { let email: String }
        return try JSONDecoder().decode(UserInfo.self, from: data).email
    }

    // MARK: - PKCE helpers

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLString()
    }

    private static func sha256Base64URL(_ s: String) -> String {
        let hash = SHA256.hash(data: Data(s.utf8))
        return Data(hash).base64URLString()
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AuthError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    enum AuthError: LocalizedError {
        case missingCredentials
        case invalidURL
        case notConnected
        case tokenRequestFailed(String)
        case deniedByUser(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Google client_id ou client_secret manquant"
            case .invalidURL:
                return "URL d'autorisation invalide"
            case .notConnected:
                return "Pas connecté à Google"
            case .tokenRequestFailed(let msg):
                return "Échec token: \(msg)"
            case .deniedByUser(let err):
                return "Autorisation refusée: \(err)"
            case .timeout:
                return "Délai d'autorisation dépassé"
            }
        }
    }
}

// MARK: - Token response & helpers

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case tokenType    = "token_type"
    }
}

private extension Data {
    func base64URLString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
