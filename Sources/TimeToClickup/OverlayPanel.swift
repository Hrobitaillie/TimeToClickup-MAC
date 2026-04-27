import AppKit
import SwiftUI

/// Borderless floating panel sitting just under the menu bar / notch.
/// The panel keeps a fixed size (sized for the expanded state); the
/// SwiftUI content scales itself between compact and expanded so the
/// hover tracking area never changes — that's what kills the flicker.
final class OverlayPanel: NSPanel {

    static let panelSize = NSSize(width: 360, height: 56)
    static weak var current: OverlayPanel?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
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

        contentView = NSHostingView(rootView: root)
        positionTopCenter()
        Self.current = self
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

    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let x = frame.midX - Self.panelSize.width / 2
        // Sit flush against the menu bar so the pill reads like a
        // Dynamic Island hanging from the notch line.
        let y = visible.maxY - Self.panelSize.height
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
