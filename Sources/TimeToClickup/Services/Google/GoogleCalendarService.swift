import Foundation

/// Thin wrapper around Google Calendar v3 events API. The auth header
/// is provided by `GoogleAuthService` (refreshed transparently when
/// expired).
@MainActor
final class GoogleCalendarService {
    static let shared = GoogleCalendarService()

    private let baseURL = "https://www.googleapis.com/calendar/v3/calendars/primary/events"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Create a new event on the primary calendar. Returns the new id.
    func createEvent(
        summary: String, description: String,
        start: Date, end: Date
    ) async throws -> String {
        let body: [String: Any] = [
            "summary": summary,
            "description": description,
            "start": ["dateTime": Self.iso.string(from: start)],
            "end":   ["dateTime": Self.iso.string(from: end)]
        ]
        let data = try await send(method: "POST", path: nil, body: body)
        struct CreateResponse: Decodable { let id: String }
        return try JSONDecoder().decode(CreateResponse.self, from: data).id
    }

    /// PATCH only the fields we care about.
    func patchEvent(
        id: String,
        summary: String? = nil,
        description: String? = nil,
        start: Date? = nil,
        end: Date? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let summary { body["summary"] = summary }
        if let description { body["description"] = description }
        if let start {
            body["start"] = ["dateTime": Self.iso.string(from: start)]
        }
        if let end {
            body["end"] = ["dateTime": Self.iso.string(from: end)]
        }
        guard !body.isEmpty else { return }
        _ = try await send(method: "PATCH", path: id, body: body)
    }

    func deleteEvent(id: String) async throws {
        _ = try await send(method: "DELETE", path: id, body: nil)
    }

    // MARK: - HTTP

    private func send(
        method: String, path: String?, body: [String: Any]?
    ) async throws -> Data {
        let token = try await GoogleAuthService.shared.accessToken()
        var url = baseURL
        if let path { url += "/\(path)" }
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CalendarError.http(code, String(body.prefix(200)))
        }
        return data
    }

    enum CalendarError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case let .http(code, body):
                return "HTTP \(code): \(body)"
            }
        }
    }
}
