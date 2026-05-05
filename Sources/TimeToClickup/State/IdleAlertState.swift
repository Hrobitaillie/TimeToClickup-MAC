import Foundation
import Combine

/// Watches `TimerState` and raises a "tu as oublié le timer" alert when
/// no timer has been running for `idleThreshold` seconds. Supports
/// snoozing (fixed durations or until a specific time).
@MainActor
final class IdleAlertState: ObservableObject {
    static let shared = IdleAlertState()

    /// True when the "you forgot the timer" yellow alert is shown.
    @Published private(set) var isAlertActive = false

    /// True when the "end of day, stop the timer" red alert is shown.
    /// Triggered when a timer is still running past the user's
    /// configured end of day (see `WorkingHoursState`).
    @Published private(set) var isEndOfDayAlertActive = false

    /// Snooze persists across launches so closing/reopening the app
    /// doesn't surprise the user with an immediate alert.
    @Published private(set) var snoozedUntil: Date?

    /// Independent snooze for the end-of-day red alert. Lives on its
    /// own so muting one doesn't mute the other.
    @Published private(set) var endOfDaySnoozedUntil: Date?

    /// Configurable. 10 min by default.
    let idleThreshold: TimeInterval = 600

    /// Last moment the timer was actively running (or app launch as a
    /// fallback). Persisted so a quick relaunch doesn't reset the
    /// countdown. Updated whenever the timer transitions running →
    /// stopped, and to `Date()` while running.
    private var lastTimerActivity: Date

    private var checkTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private let snoozeKey = "idle_alert_snoozed_until"
    private let lastActivityKey = "idle_alert_last_activity"
    private let eodSnoozeKey = "idle_eod_snoozed_until"

    private init() {
        let stored = UserDefaults.standard.object(forKey: lastActivityKey) as? Date
        self.lastTimerActivity = stored ?? Date()

        if let s = UserDefaults.standard.object(forKey: snoozeKey) as? Date,
           s > Date() {
            self.snoozedUntil = s
        }
        if let s = UserDefaults.standard.object(forKey: eodSnoozeKey) as? Date,
           s > Date() {
            self.endOfDaySnoozedUntil = s
        }
    }

    /// Wire up subscriptions and start the periodic check. Called once
    /// from AppDelegate after singletons are alive.
    func startMonitoring() {
        // Track timer running ↔ stopped transitions so we know when the
        // last "real" activity happened. `.dropFirst()` is critical:
        // Combine replays the current value to new subscribers, and we
        // don't want that initial `false` to overwrite the persisted
        // `lastTimerActivity` (which would silently kill the alert).
        TimerState.shared.$isRunning
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] running in
                guard let self else { return }
                self.lastTimerActivity = Date()
                UserDefaults.standard.set(
                    self.lastTimerActivity, forKey: self.lastActivityKey
                )
                if running {
                    // Active session — no need to alert. Also clear any
                    // snooze so a stop-then-restart-much-later cycle
                    // doesn't get accidentally muted.
                    self.clearSnooze()
                    self.isAlertActive = false
                } else {
                    self.recompute()
                }
            }
            .store(in: &cancellables)

        // Periodic recompute — the running flag doesn't tell us when
        // the threshold elapses, only the wall clock does.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recompute() }
        }
        RunLoop.main.add(t, forMode: .common)
        checkTimer = t

        recompute()
    }

    /// Recomputes both alerts from the current state. Idempotent.
    func recompute() {
        recomputeIdle()
        recomputeEndOfDay()
    }

    private func recomputeIdle() {
        // Running timer → never alert (and the EOD alert may take over
        // instead, handled separately).
        if TimerState.shared.isRunning {
            if isAlertActive { isAlertActive = false }
            // Refresh the activity stamp so a long uninterrupted
            // running stint doesn't immediately alert on stop.
            lastTimerActivity = Date()
            UserDefaults.standard.set(
                lastTimerActivity, forKey: lastActivityKey
            )
            return
        }

        // Snoozed and still in the future → muted.
        if let until = snoozedUntil, until > Date() {
            if isAlertActive { isAlertActive = false }
            return
        }
        if snoozedUntil != nil { clearSnooze() }

        let elapsed = Date().timeIntervalSince(lastTimerActivity)
        let shouldAlert = elapsed >= idleThreshold
        if shouldAlert != isAlertActive { isAlertActive = shouldAlert }
    }

    private func recomputeEndOfDay() {
        let hours = WorkingHoursState.shared
        // Guard: timer must be running, today must be a working day,
        // and the global hours toggle must be on.
        guard TimerState.shared.isRunning,
              let endOfDay = hours.endOfDayToday
        else {
            if isEndOfDayAlertActive { isEndOfDayAlertActive = false }
            return
        }

        if let until = endOfDaySnoozedUntil, until > Date() {
            if isEndOfDayAlertActive { isEndOfDayAlertActive = false }
            return
        }
        if endOfDaySnoozedUntil != nil { clearEndOfDaySnooze() }

        let past = Date() >= endOfDay
        if past != isEndOfDayAlertActive { isEndOfDayAlertActive = past }
    }

    // MARK: - Snooze

    func snooze(for duration: TimeInterval) {
        snooze(until: Date().addingTimeInterval(duration))
    }

    func snooze(until date: Date) {
        snoozedUntil = date
        UserDefaults.standard.set(date, forKey: snoozeKey)
        isAlertActive = false
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        LogStore.shared.info(
            "🔕 Alerte « oubli timer » mise en sourdine jusqu'à \(formatter.string(from: date))"
        )
    }

    func clearSnooze() {
        guard snoozedUntil != nil else { return }
        snoozedUntil = nil
        UserDefaults.standard.removeObject(forKey: snoozeKey)
    }

    /// Snooze until end of day (23:59).
    func snoozeUntilEndOfDay() {
        var comps = Calendar.current.dateComponents(
            [.year, .month, .day], from: Date()
        )
        comps.hour = 23
        comps.minute = 59
        if let d = Calendar.current.date(from: comps) {
            snooze(until: d)
        }
    }

    // MARK: - End-of-day snooze (independent track)

    func snoozeEndOfDay(for duration: TimeInterval) {
        snoozeEndOfDay(until: Date().addingTimeInterval(duration))
    }

    func snoozeEndOfDay(until date: Date) {
        endOfDaySnoozedUntil = date
        UserDefaults.standard.set(date, forKey: eodSnoozeKey)
        isEndOfDayAlertActive = false
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        LogStore.shared.info(
            "🔕 Alerte « fin de journée » mise en sourdine jusqu'à \(f.string(from: date))"
        )
    }

    func clearEndOfDaySnooze() {
        guard endOfDaySnoozedUntil != nil else { return }
        endOfDaySnoozedUntil = nil
        UserDefaults.standard.removeObject(forKey: eodSnoozeKey)
    }
}
