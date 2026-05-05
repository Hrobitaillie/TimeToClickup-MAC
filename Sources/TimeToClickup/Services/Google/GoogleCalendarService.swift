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

    /// Fetches timed events that overlap with `now` on the primary
    /// calendar — i.e. meetings the user is currently in. Skips all-day
    /// events (they have a `date` field, not `dateTime`).
    func currentMeetings(reference: Date = Date()) async throws -> [Meeting] {
        let timeMin = reference.addingTimeInterval(-12 * 3600)
        let timeMax = reference.addingTimeInterval(2 * 3600)
        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: Self.iso.string(from: timeMin)),
            URLQueryItem(name: "timeMax", value: Self.iso.string(from: timeMax)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50")
        ]

        let token = try await GoogleAuthService.shared.accessToken()
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CalendarError.http(code, String(body.prefix(200)))
        }

        let resp = try JSONDecoder().decode(EventsListResponse.self, from: data)
        return resp.items.compactMap { item -> Meeting? in
            guard let startStr = item.start?.dateTime,
                  let endStr = item.end?.dateTime,
                  let start = Self.iso.date(from: startStr),
                  let end = Self.iso.date(from: endStr) else { return nil }
            // Only ongoing right now — start <= reference < end.
            guard start <= reference, reference < end else { return nil }
            return Meeting(
                id: item.id,
                summary: item.summary ?? "Réunion sans titre",
                start: start,
                end: end
            )
        }
    }

    /// Meetings that ended in the last `lookback` window. Useful as a
    /// "backdate the timer to the end of my last meeting" shortcut. We
    /// return them most-recent-first.
    func recentlyEndedMeetings(
        reference: Date = Date(),
        lookback: TimeInterval = 4 * 3600
    ) async throws -> [Meeting] {
        let timeMin = reference.addingTimeInterval(-lookback)
        let timeMax = reference
        var components = URLComponents(string: baseURL)!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: Self.iso.string(from: timeMin)),
            URLQueryItem(name: "timeMax", value: Self.iso.string(from: timeMax)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50")
        ]

        let token = try await GoogleAuthService.shared.accessToken()
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CalendarError.http(code, String(body.prefix(200)))
        }

        let resp = try JSONDecoder().decode(EventsListResponse.self, from: data)
        let meetings = resp.items.compactMap { item -> Meeting? in
            guard let startStr = item.start?.dateTime,
                  let endStr = item.end?.dateTime,
                  let start = Self.iso.date(from: startStr),
                  let end = Self.iso.date(from: endStr) else { return nil }
            // Strictly ended in the past, started before now.
            guard end <= reference, start <= reference else { return nil }
            return Meeting(
                id: item.id,
                summary: item.summary ?? "Réunion sans titre",
                start: start,
                end: end
            )
        }
        return meetings.sorted { $0.end > $1.end }
    }

    struct Meeting: Identifiable, Hashable, Sendable {
        let id: String
        let summary: String
        let start: Date
        let end: Date
    }

    private struct EventsListResponse: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let id: String
            let summary: String?
            let start: TimePoint?
            let end: TimePoint?
        }
        struct TimePoint: Decodable {
            let dateTime: String?
            let date: String?
        }
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
