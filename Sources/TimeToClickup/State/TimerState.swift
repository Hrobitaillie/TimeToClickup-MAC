import Foundation
import Combine
import AppKit

@MainActor
final class TimerState: ObservableObject {
    static let shared = TimerState()

    @Published var isRunning = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var currentTask: ClickUpTask?
    @Published var taskDescription: String = ""

    /// The id of the ClickUp time-entry the local timer is mirroring.
    /// Lets us detect when the user starts/stops a different entry on
    /// ClickUp (web/mobile) and stay in sync.
    private var currentEntryId: String?

    private var startedAt: Date?
    private var ticker: Timer?
    private var syncTimer: Timer?

    /// Read-only access for the calendar coordinator.
    var startTime: Date? { startedAt }

    private let syncInterval: TimeInterval = 15

    var formatted: String {
        let total = Int(elapsedTime)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    // MARK: - User actions (push to ClickUp)

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        startedAt = Date()
        elapsedTime = 0
        isRunning = true
        currentEntryId = nil
        scheduleTick()

        CalendarSyncCoordinator.shared.timerDidStart()

        // Push to ClickUp. Only sync from server if the start
        // succeeded — otherwise the next poll would see "nothing
        // running" and stop the local timer, which is not what we
        // want when ClickUp simply rejected the request.
        let taskId = currentTask?.id
        Task {
            let id = await ClickUpService.shared.startTimeEntry(
                taskId: taskId
            )
            guard let id else { return }
            self.currentEntryId = id
            await self.syncFromServer()
        }
    }

    func stop() {
        guard isRunning else { return }
        // Capture state for the coordinator BEFORE we clear it — the
        // calendar event needs the still-current task/description.
        CalendarSyncCoordinator.shared.timerWillStop()

        let hadEntry = currentEntryId != nil
        ticker?.invalidate()
        ticker = nil
        isRunning = false
        startedAt = nil
        elapsedTime = 0
        currentTask = nil
        currentEntryId = nil
        taskDescription = ""

        if hadEntry {
            Task { await ClickUpService.shared.stopTimeEntry() }
        }
    }

    func attach(task: ClickUpTask) {
        let wasRunning = isRunning
        let entryId = currentEntryId
        currentTask = task
        taskDescription = ""
        ClickUpService.shared.markRecent(task)
        CalendarSyncCoordinator.shared.timerInfoDidChange()

        if wasRunning, let entryId {
            // We already have a running entry on ClickUp — just patch
            // its `tid` so the timer keeps going, no stop+start churn.
            Task {
                await ClickUpService.shared.updateTimeEntryTask(
                    entryId: entryId, taskId: task.id
                )
                await self.syncFromServer()
            }
            return
        }

        if !wasRunning { return }

        // Running locally but no server entry yet (rare race): start a
        // fresh entry now.
        Task {
            let id = await ClickUpService.shared.startTimeEntry(
                taskId: task.id
            )
            if let id { self.currentEntryId = id }
            await self.syncFromServer()
        }
    }

    // MARK: - Server sync

    /// Begin polling ClickUp every `syncInterval` seconds for the
    /// currently running entry, and apply any change to the local state.
    func startSyncing() {
        Task { await syncFromServer() }
        syncTimer?.invalidate()
        let t = Timer(timeInterval: syncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncFromServer()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        syncTimer = t
    }

    private func syncFromServer() async {
        let entry = await ClickUpService.shared.currentRunningEntry()
        apply(serverEntry: entry)
    }

    private func apply(serverEntry: RunningEntry?) {
        guard let entry = serverEntry else {
            // Only honour "server has nothing" when we were actually
            // mirroring an entry. A purely local timer (e.g. ClickUp
            // refused the start) shouldn't be killed by every poll.
            if isRunning, currentEntryId != nil { stopLocally() }
            return
        }

        // Prefer the local clock when the user clicked play before the
        // task was attached — otherwise the displayed time would jump
        // backwards to the server's later start.
        let preferLocal: Bool
        if let local = startedAt, local < entry.startedAt {
            preferLocal = true
        } else {
            preferLocal = false
        }

        if currentEntryId == entry.id, isRunning {
            if !preferLocal { startedAt = entry.startedAt }
            if let s = startedAt {
                elapsedTime = Date().timeIntervalSince(s)
            }
            updateTaskIfNeeded(entry: entry)
            return
        }

        // New / different entry on the server.
        ticker?.invalidate()
        currentEntryId = entry.id
        if !preferLocal { startedAt = entry.startedAt }
        if let s = startedAt {
            elapsedTime = Date().timeIntervalSince(s)
        }
        isRunning = true
        updateTaskIfNeeded(entry: entry)
        scheduleTick()
    }

    private func updateTaskIfNeeded(entry: RunningEntry) {
        // Pull description through unless the user has just edited it
        // locally (we only overwrite if it changed on the server).
        let serverDesc = entry.description ?? ""
        if serverDesc != taskDescription { taskDescription = serverDesc }

        guard let taskId = entry.taskId else {
            if currentTask != nil { currentTask = nil }
            return
        }
        if currentTask?.id == taskId { return }
        currentTask = ClickUpTask(
            id: taskId,
            name: entry.taskName ?? "Tâche \(taskId)",
            status: nil,
            listName: nil,
            folderName: nil,
            spaceName: nil,
            url: nil
        )
    }

    /// Update the description on the running entry. Pushed to ClickUp
    /// immediately; local copy stays in sync.
    func setDescription(_ text: String) {
        taskDescription = text
        CalendarSyncCoordinator.shared.timerInfoDidChange()
        guard let entryId = currentEntryId else { return }
        Task {
            await ClickUpService.shared.updateTimeEntryDescription(
                entryId: entryId, description: text
            )
        }
    }

    private func stopLocally() {
        ticker?.invalidate()
        ticker = nil
        isRunning = false
        startedAt = nil
        elapsedTime = 0
        currentTask = nil
        currentEntryId = nil
        taskDescription = ""
    }

    private func scheduleTick() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsedTime = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }
}
