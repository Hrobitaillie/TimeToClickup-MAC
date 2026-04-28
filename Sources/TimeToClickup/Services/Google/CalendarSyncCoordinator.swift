import Foundation
import Combine

/// Orchestrates the lifecycle of a calendar event mirroring a running
/// timer:
///
/// - **enabled toggle ON + timer running** → create an event
///   (start = `timer.startedAt`, end = now + 15 min) with a `🔴 ` prefix
///   so it reads as "in progress" in Google Calendar.
/// - **every 15 min** while still running → PATCH `end` to now + 15 min
///   so the slot keeps appearing as the upcoming time.
/// - **timer stops / toggle OFF** → PATCH `end` to the actual stop
///   time and strip the `🔴 ` prefix from the title.
/// - **task or description changes** → PATCH summary / description.
@MainActor
final class CalendarSyncCoordinator: ObservableObject {
    static let shared = CalendarSyncCoordinator()

    @Published private(set) var enabled: Bool
    @Published private(set) var hasActiveEvent: Bool = false

    private let enabledKey = "calendar_sync_enabled"
    private let extendInterval: TimeInterval = 15 * 60   // tick every 15 min
    private let lookahead: TimeInterval     = 15 * 60    // event extends 15 min ahead
    private let runningPrefix = "🔴 "
    private let runningSuffix = " — ⏳ Tracking en cours"

    private var activeEventId: String?
    private var extendTimer: Timer?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: enabledKey)
    }

    // MARK: - Toggle

    func toggle() {
        let on = !enabled
        enabled = on
        UserDefaults.standard.set(on, forKey: enabledKey)
        LogStore.shared.info(
            on ? "📅 Sync calendrier ACTIVÉE" : "📅 Sync calendrier DÉSACTIVÉE"
        )

        if on, TimerState.shared.isRunning {
            Task { await createEventForCurrentTimer() }
        } else if !on, let id = activeEventId {
            finalizeNow(eventId: id)
        }
    }

    // MARK: - Hooks called from TimerState

    func timerDidStart() {
        guard enabled, GoogleAuthService.shared.isConnected else { return }
        Task { await createEventForCurrentTimer() }
    }

    /// Capture state synchronously while it's still set, then finalize
    /// asynchronously.
    func timerWillStop() {
        guard let id = activeEventId else { return }
        finalizeNow(eventId: id)
    }

    func timerInfoDidChange() {
        guard let id = activeEventId else { return }
        let summary = runningSummary(for: TimerState.shared.currentTask)
        let description = currentDescription()
        LogStore.shared.info("📅 → PATCH event « \(summary) »")
        if !description.isEmpty {
            LogStore.shared.info("    description: \(description.prefix(200))")
        }
        Task {
            do {
                try await GoogleCalendarService.shared.patchEvent(
                    id: id, summary: summary, description: description
                )
            } catch {
                LogStore.shared.error(
                    "Calendar update: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Internals

    private func createEventForCurrentTimer() async {
        guard activeEventId == nil else { return }
        let timer = TimerState.shared
        guard timer.isRunning, let started = timer.startTime else { return }

        let endTime = max(
            Date().addingTimeInterval(lookahead),
            started.addingTimeInterval(lookahead)
        )
        let summary = runningSummary(for: timer.currentTask)
        let description = currentDescription()

        LogStore.shared.info("📅 → Création event « \(summary) »")
        if !description.isEmpty {
            LogStore.shared.info("    description: \(description.prefix(200))")
        } else {
            LogStore.shared.warn("    (description vide — task sans path/URL ?)")
        }

        do {
            let id = try await GoogleCalendarService.shared.createEvent(
                summary: summary, description: description,
                start: started, end: endTime
            )
            activeEventId = id
            hasActiveEvent = true
            scheduleExtendTimer()
            LogStore.shared.info("📅 ← Event créé (id \(id))")
        } catch {
            LogStore.shared.error(
                "Calendar create: \(error.localizedDescription)"
            )
        }
    }

    private func extendActiveEvent() async {
        guard let id = activeEventId else { return }
        let endTime = Date().addingTimeInterval(lookahead)
        do {
            try await GoogleCalendarService.shared.patchEvent(
                id: id, end: endTime
            )
            LogStore.shared.info("📅 Event prolongé (+15 min)")
        } catch {
            LogStore.shared.error(
                "Calendar extend: \(error.localizedDescription)"
            )
        }
    }

    /// Synchronous capture, then async PATCH. Resets local state
    /// immediately so subsequent hooks don't double-finalize.
    private func finalizeNow(eventId: String) {
        let summary = finalSummary(for: TimerState.shared.currentTask)
        let description = currentDescription(running: false)
        let endTime = Date()

        activeEventId = nil
        hasActiveEvent = false
        extendTimer?.invalidate()
        extendTimer = nil

        Task {
            do {
                try await GoogleCalendarService.shared.patchEvent(
                    id: eventId,
                    summary: summary,
                    description: description,
                    end: endTime
                )
                LogStore.shared.info("✓ Calendar: event finalisé")
            } catch {
                LogStore.shared.error(
                    "Calendar finalize: \(error.localizedDescription)"
                )
            }
        }
    }

    private func scheduleExtendTimer() {
        extendTimer?.invalidate()
        let t = Timer(timeInterval: extendInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.extendActiveEvent()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        extendTimer = t
    }

    // MARK: - Formatting

    private func runningSummary(for task: ClickUpTask?) -> String {
        runningPrefix + (task?.name ?? "Time entry") + runningSuffix
    }

    private func finalSummary(for task: ClickUpTask?) -> String {
        task?.name ?? "Time entry"
    }

    private func currentDescription(running: Bool = true) -> String {
        let timer = TimerState.shared
        var parts: [String] = []
        if running {
            parts.append("⏳ Tracking en cours — fin indéterminée")
        }
        if !timer.taskDescription.isEmpty {
            parts.append(timer.taskDescription)
        }
        if let task = timer.currentTask {
            let path = [task.spaceName, task.folderName, task.listName]
                .compactMap { $0 }
                .filter { !$0.isEmpty && $0 != "hidden" }
                .joined(separator: " › ")
            if !path.isEmpty { parts.append("📂 \(path)") }
            if let url = task.url, !url.isEmpty {
                parts.append("🔗 \(url)")
            }
        }
        return parts.joined(separator: "\n\n")
    }
}
