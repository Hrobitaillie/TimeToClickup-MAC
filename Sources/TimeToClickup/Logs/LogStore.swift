import Foundation
import SwiftUI

@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    @Published private(set) var entries: [LogEntry] = []

    private let maxEntries = 400

    private init() {}

    func info(_ message: String)  { append(.info, message) }
    func warn(_ message: String)  { append(.warning, message) }
    func error(_ message: String) { append(.error, message) }

    func clear() { entries.removeAll() }

    private func append(_ level: LogEntry.Level, _ message: String) {
        entries.append(LogEntry(level: level, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}

struct LogEntry: Identifiable {
    enum Level {
        case info, warning, error

        var symbol: String {
            switch self {
            case .info:    return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error:   return "xmark.octagon"
            }
        }

        var color: Color {
            switch self {
            case .info:    return .secondary
            case .warning: return .orange
            case .error:   return .red
            }
        }
    }

    let id = UUID()
    let timestamp = Date()
    let level: Level
    let message: String
}
