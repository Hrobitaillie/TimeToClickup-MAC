import Foundation
import Combine
import SwiftUI

/// Time-of-day stored as minutes since midnight. Easier to persist
/// and compare than `Date`s — we only ever care about HH:MM, not the
/// actual day.
struct TimeOfDay: Codable, Equatable, Hashable {
    var hour: Int
    var minute: Int

    var minutesSinceMidnight: Int { hour * 60 + minute }

    static func from(date: Date) -> TimeOfDay {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    func dateOnToday() -> Date {
        var c = Calendar.current.dateComponents(
            [.year, .month, .day], from: Date()
        )
        c.hour = hour
        c.minute = minute
        return Calendar.current.date(from: c) ?? Date()
    }

    var formatted: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// Schedule for a single weekday: morning + afternoon blocks, plus a
/// per-day enabled toggle so weekends can be off without rewriting
/// the times every time.
struct DaySchedule: Codable, Equatable {
    var enabled: Bool
    var morningStart: TimeOfDay
    var morningEnd: TimeOfDay
    var afternoonStart: TimeOfDay
    var afternoonEnd: TimeOfDay

    static let workdayDefault = DaySchedule(
        enabled: true,
        morningStart:   TimeOfDay(hour: 9, minute: 0),
        morningEnd:     TimeOfDay(hour: 12, minute: 30),
        afternoonStart: TimeOfDay(hour: 14, minute: 0),
        afternoonEnd:   TimeOfDay(hour: 18, minute: 0)
    )
    static let fridayDefault = DaySchedule(
        enabled: true,
        morningStart:   TimeOfDay(hour: 9, minute: 0),
        morningEnd:     TimeOfDay(hour: 12, minute: 30),
        afternoonStart: TimeOfDay(hour: 14, minute: 0),
        afternoonEnd:   TimeOfDay(hour: 17, minute: 0)
    )
    static let weekendDefault = DaySchedule(
        enabled: false,
        morningStart:   TimeOfDay(hour: 9, minute: 0),
        morningEnd:     TimeOfDay(hour: 12, minute: 30),
        afternoonStart: TimeOfDay(hour: 14, minute: 0),
        afternoonEnd:   TimeOfDay(hour: 18, minute: 0)
    )
}

/// Calendar weekday — using `Calendar.component(.weekday)` convention
/// (Sunday = 1 … Saturday = 7) so lookups against `Date` are direct.
enum Weekday: Int, CaseIterable, Codable, Identifiable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
    var id: Int { rawValue }

    /// Human label in French.
    var label: String {
        switch self {
        case .monday: return "Lundi"
        case .tuesday: return "Mardi"
        case .wednesday: return "Mercredi"
        case .thursday: return "Jeudi"
        case .friday: return "Vendredi"
        case .saturday: return "Samedi"
        case .sunday: return "Dimanche"
        }
    }

    /// Mon = 0 … Sun = 6 — used to display the week starting Monday.
    var orderIndex: Int {
        switch self {
        case .monday: return 0
        case .tuesday: return 1
        case .wednesday: return 2
        case .thursday: return 3
        case .friday: return 4
        case .saturday: return 5
        case .sunday: return 6
        }
    }

    static var orderedMondayFirst: [Weekday] {
        Weekday.allCases.sorted { $0.orderIndex < $1.orderIndex }
    }
}

/// User's typical work schedule, indexed by weekday so Friday can end
/// earlier than the rest of the week, and weekends can be off.
@MainActor
final class WorkingHoursState: ObservableObject {
    static let shared = WorkingHoursState()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: enabledKey) }
    }

    /// Map weekday → schedule. Mutating the dict (e.g. through subscript
    /// in the UI) triggers persistence via `didSet`.
    @Published var schedules: [Weekday: DaySchedule] {
        didSet { persist() }
    }

    private let enabledKey = "working_hours_enabled"
    private let key = "working_hours_v2"
    /// Old single-schedule key — used to migrate existing settings to
    /// the per-weekday model on first launch.
    private let legacyKey = "working_hours_v1"

    private init() {
        self.enabled = UserDefaults.standard.bool(forKey: enabledKey)

        if let data = UserDefaults.standard.data(forKey: key),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            self.schedules = stored.toDict()
        } else if let legacyData = UserDefaults.standard.data(forKey: legacyKey),
                  let legacy = try? JSONDecoder().decode(
                    LegacyStored.self, from: legacyData
                  ) {
            // Migrate single-schedule → Mon-Fri use legacy times,
            // weekend disabled.
            var dict = Self.defaultSchedules()
            for day in [Weekday.monday, .tuesday, .wednesday, .thursday] {
                dict[day] = DaySchedule(
                    enabled: true,
                    morningStart: legacy.morningStart,
                    morningEnd: legacy.morningEnd,
                    afternoonStart: legacy.afternoonStart,
                    afternoonEnd: legacy.afternoonEnd
                )
            }
            // Friday: keep morning, but afternoon ends 1 h earlier.
            var fri = dict[.friday] ?? DaySchedule.fridayDefault
            fri.morningStart = legacy.morningStart
            fri.morningEnd = legacy.morningEnd
            fri.afternoonStart = legacy.afternoonStart
            dict[.friday] = fri
            self.schedules = dict
            UserDefaults.standard.removeObject(forKey: legacyKey)
        } else {
            self.schedules = Self.defaultSchedules()
        }
    }

    private static func defaultSchedules() -> [Weekday: DaySchedule] {
        [
            .monday:    .workdayDefault,
            .tuesday:   .workdayDefault,
            .wednesday: .workdayDefault,
            .thursday:  .workdayDefault,
            .friday:    .fridayDefault,
            .saturday:  .weekendDefault,
            .sunday:    .weekendDefault
        ]
    }

    /// Convenient subscript — used by SwiftUI bindings in the settings UI.
    func binding(for day: Weekday) -> Binding<DaySchedule> {
        Binding(
            get: { self.schedules[day] ?? .weekendDefault },
            set: { self.schedules[day] = $0 }
        )
    }

    /// End of today's work day, or nil if today is off / hours are
    /// globally disabled. Used by `IdleAlertState` to decide when to
    /// raise the red "fin de journée" alert.
    var endOfDayToday: Date? {
        guard enabled else { return nil }
        let weekdayInt = Calendar.current.component(.weekday, from: Date())
        guard let weekday = Weekday(rawValue: weekdayInt),
              let schedule = schedules[weekday],
              schedule.enabled
        else { return nil }
        return schedule.afternoonEnd.dateOnToday()
    }

    private func persist() {
        let stored = Stored(from: schedules)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private struct Stored: Codable {
        let monday: DaySchedule
        let tuesday: DaySchedule
        let wednesday: DaySchedule
        let thursday: DaySchedule
        let friday: DaySchedule
        let saturday: DaySchedule
        let sunday: DaySchedule

        init(from dict: [Weekday: DaySchedule]) {
            self.monday    = dict[.monday]    ?? .workdayDefault
            self.tuesday   = dict[.tuesday]   ?? .workdayDefault
            self.wednesday = dict[.wednesday] ?? .workdayDefault
            self.thursday  = dict[.thursday]  ?? .workdayDefault
            self.friday    = dict[.friday]    ?? .fridayDefault
            self.saturday  = dict[.saturday]  ?? .weekendDefault
            self.sunday    = dict[.sunday]    ?? .weekendDefault
        }

        func toDict() -> [Weekday: DaySchedule] {
            [
                .monday: monday, .tuesday: tuesday, .wednesday: wednesday,
                .thursday: thursday, .friday: friday,
                .saturday: saturday, .sunday: sunday
            ]
        }
    }

    /// Old shape — single schedule shared across all weekdays. Kept
    /// only to migrate existing UserDefaults entries.
    private struct LegacyStored: Codable {
        let morningStart: TimeOfDay
        let morningEnd: TimeOfDay
        let afternoonStart: TimeOfDay
        let afternoonEnd: TimeOfDay
    }
}
