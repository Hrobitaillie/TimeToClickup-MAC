import AppKit
import SwiftUI
import Combine

/// Borderless floating panel sitting just under the menu bar / notch.
/// At rest the panel keeps a fixed size — the SwiftUI content scales
/// itself between compact and expanded so the hover tracking area
/// never changes (that's what kills the flicker). The panel only
/// resizes for stable, non-hover state changes (e.g. the idle alert),
/// which are infrequent enough not to retrigger hover events.
final class OverlayPanel: NSPanel {

    /// 80pt tall (instead of just-fits) so the expanded pill's drop
    /// shadow renders inside the panel. Otherwise NSPanel clips it.
    static let normalSize = NSSize(width: 360, height: 80)
    static let alertSize = NSSize(width: 472, height: 80)
    static var panelSize: NSSize { normalSize }
    static weak var current: OverlayPanel?

    /// User-configurable preferred display. Stored as a `CGDirectDisplayID`
    /// (UInt32) in UserDefaults. `nil` → use `NSScreen.main`.
    static let preferredDisplayKey = "preferred_display_id"

    static var preferredDisplayID: CGDirectDisplayID? {
        get {
            let raw = UserDefaults.standard.integer(forKey: preferredDisplayKey)
            return raw == 0 ? nil : CGDirectDisplayID(raw)
        }
        set {
            if let id = newValue {
                UserDefaults.standard.set(Int(id), forKey: preferredDisplayKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredDisplayKey)
            }
            // Reposition the live panel right away so the change is
            // visible without restarting.
            current?.repositionForCurrentScreen()
        }
    }

    /// Resolves the screen we should pin the overlay to: the
    /// user-preferred one if it's still attached, otherwise the
    /// system's main screen.
    static func targetScreen() -> NSScreen? {
        if let preferred = preferredDisplayID,
           let match = NSScreen.screens.first(where: {
               ($0.deviceDescription[
                   NSDeviceDescriptionKey("NSScreenNumber")
               ] as? CGDirectDisplayID) == preferred
           }) {
            return match
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private var alertCancellable: AnyCancellable?
    private var screenObserver: Any?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.normalSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let root = OverlayView()
            .environmentObject(TimerState.shared)
            .environmentObject(ClickUpService.shared)
            .environmentObject(SearchController.shared)
            .environmentObject(DescriptionController.shared)
            .environmentObject(CalendarSyncCoordinator.shared)
            .environmentObject(IdleAlertState.shared)

        contentView = NSHostingView(rootView: root)
        positionTopCenter()
        Self.current = self

        // Resize when either alert toggles. These are stable state
        // changes (30s tick or button press), not hover-driven — so
        // they don't fight the hover-flicker rule.
        let idle = IdleAlertState.shared
        alertCancellable = Publishers.CombineLatest(
            idle.$isAlertActive, idle.$isEndOfDayAlertActive
        )
        .map { $0 || $1 }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] active in
            self?.applySize(active ? Self.alertSize : Self.normalSize)
        }

        // Reposition automatically when displays are added / removed
        // (lid open, monitor connect/disconnect, etc.) so the pill
        // stays on the user's preferred screen.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.repositionForCurrentScreen()
        }
    }

    deinit {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // Must return true so the search popover's TextField can receive
    // keyboard input. Combined with `.nonactivatingPanel`, the panel
    // becomes key without activating our app — keystrokes land in the
    // search field instead of the front app underneath.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func show() {
        positionTopCenter()
        orderFrontRegardless()
    }

    /// Re-runs the positioning logic — called when the user picks a
    /// different preferred display in Settings, or when displays are
    /// added/removed.
    func repositionForCurrentScreen() {
        applySize(self.frame.size)
    }

    private func applySize(_ size: NSSize) {
        guard let screen = Self.targetScreen() else {
            setContentSize(size)
            return
        }
        let visible = screen.visibleFrame
        let frame = screen.frame
        let x = frame.midX - size.width / 2
        let y = visible.maxY - size.height
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                 display: true, animate: false)
    }

    private func positionTopCenter() {
        guard let screen = Self.targetScreen() else { return }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let size = self.frame.size
        let x = frame.midX - size.width / 2
        // Sit flush against the menu bar so the pill reads like a
        // Dynamic Island hanging from the notch line.
        let y = visible.maxY - size.height
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
