import AppKit
import SwiftUI

/// Floating panel hosting the ClickUp task autocomplete. Anchored
/// underneath the overlay; auto-dismisses on focus loss or Escape.
@MainActor
final class SearchPanel: NSPanel {

    static let panelSize = NSSize(width: 384, height: 392)

    private var keyMonitor: Any?

    init(onPick: @escaping (ClickUpTask) -> Void) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        hidesOnDeactivate = false

        let content = TaskSearchView(onPick: { task in
            onPick(task)
            SearchController.shared.close()
        })
        .environmentObject(ClickUpService.shared)
        .frame(width: Self.panelSize.width - 24, height: Self.panelSize.height - 24)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.36), radius: 28, y: 14)
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(12)

        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(below anchor: NSRect) {
        // Right-align with the source overlay; clamp to the screen.
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let raw = NSPoint(
            x: anchor.maxX - Self.panelSize.width + 12,
            y: anchor.minY - Self.panelSize.height
        )
        let x = min(max(raw.x, screenFrame.minX + 4),
                    screenFrame.maxX - Self.panelSize.width - 4)
        setFrameOrigin(NSPoint(x: x, y: raw.y))
        makeKeyAndOrderFront(nil)
        installEscapeMonitor()
    }

    func dismiss() {
        removeEscapeMonitor()
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        // Closing during the resignKey hop crashes; do it on the next run loop.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isKeyWindow else { return }
            SearchController.shared.close()
        }
    }

    private func installEscapeMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // Escape
                SearchController.shared.close()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }
}
