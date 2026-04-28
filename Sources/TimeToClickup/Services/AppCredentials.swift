import Foundation

/// Reads credentials shipped with the app from
/// `Contents/Resources/credentials.env` (a copy of the project root
/// `.env`). The Google OAuth client_id and client_secret belong to the
/// app, not to each user — bundling them means users don't have to set
/// up their own Google Cloud project.
///
/// Format (one per line):
/// ```
/// GOOGLE_CLIENT_ID=xxxx.apps.googleusercontent.com
/// GOOGLE_CLIENT_SECRET=GOCSPX-yyyy
/// ```
enum AppCredentials {
    private static let values: [String: String] = loadFromBundle()

    static var googleClientId: String? {
        (values["GOOGLE_CLIENT_ID"] ?? values["GOOGLE_AUTH_CLIENT"])?.nonEmpty
    }

    static var googleClientSecret: String? {
        (values["GOOGLE_CLIENT_SECRET"] ?? values["GOOGLE_AUTH_SECRET"])?.nonEmpty
    }

    static var hasBundledGoogleCredentials: Bool {
        googleClientId != nil && googleClientSecret != nil
    }

    private static func loadFromBundle() -> [String: String] {
        guard let url = Bundle.main.url(
                forResource: "credentials", withExtension: "env"
              ),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else {
            return [:]
        }

        var out: [String: String] = [:]
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
                .trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
               || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
