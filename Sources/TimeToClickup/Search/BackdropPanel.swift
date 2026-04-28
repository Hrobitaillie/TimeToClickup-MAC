import AppKit
import SwiftUI

/// Full-screen semi-transparent panel that sits behind a modal popup
/// (search / description). Clicking it dismisses the popup. Used in
/// place of a drop shadow to cleanly separate the popup from the rest
/// of the UI.
@MainActor
final class BackdropPanel: NSPanel {

    init() {
        let frame = NSScreen.main?.frame
            ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Below our own UI (overlay pill at .statusBar, search/desc
        // panels at .popUpMenu) so all of those stay fully bright on
        // top. The backdrop only dims the desktop and other apps'
        // windows underneath.
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let host = NSHostingView(
            rootView: BackdropView { SearchController.shared.close() }
        )
        host.frame = frame
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        if let screen = NSScreen.main {
            setFrame(screen.frame, display: false)
        }
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 1.0
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

private struct BackdropView: View {
    let onTap: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.32))
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
    }
}
