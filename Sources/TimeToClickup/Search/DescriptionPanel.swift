import AppKit
import SwiftUI

@MainActor
final class DescriptionController: ObservableObject {
    static let shared = DescriptionController()

    @Published private(set) var isOpen = false
    private var panel: DescriptionPanel?

    func toggle(anchor: NSRect, initial: String) {
        isOpen ? close() : open(anchor: anchor, initial: initial)
    }

    func open(anchor: NSRect, initial: String) {
        // Always rebuild so the editor's initial value is fresh.
        panel?.dismiss()
        panel = DescriptionPanel(initial: initial) { text in
            TimerState.shared.setDescription(text)
        }
        panel?.show(below: anchor)
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        panel?.dismiss()
        isOpen = false
    }
}

@MainActor
final class DescriptionPanel: NSPanel {

    static let panelSize = NSSize(width: 340, height: 168)

    private var keyMonitor: Any?

    init(initial: String, onSave: @escaping (String) -> Void) {
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

        let content = DescriptionEditor(
            initial: initial,
            onSave: { text in
                onSave(text)
                DescriptionController.shared.close()
            },
            onCancel: { DescriptionController.shared.close() }
        )
        .frame(width: Self.panelSize.width - 24,
               height: Self.panelSize.height - 24)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .padding(12)

        contentView = NSHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(below anchor: NSRect) {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        // Right-align with the overlay, then clamp.
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
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isKeyWindow else { return }
            DescriptionController.shared.close()
        }
    }

    private func installEscapeMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // Escape
                DescriptionController.shared.close()
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

private struct DescriptionEditor: View {
    @State private var text: String
    @State private var fieldFocused = false
    @FocusState private var focused: Bool

    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(initial: String,
         onSave: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        _text = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Description du timer")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("⌘↵")
                    .font(.system(size: 9, weight: .semibold,
                                  design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.18))
                    )
                    .foregroundStyle(.secondary)
            }

            TextField("Note pour ce timer…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(2...4)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            Color.accentColor.opacity(fieldFocused ? 0.55 : 0),
                            lineWidth: fieldFocused ? 1.2 : 0
                        )
                )
                .focused($focused)
                .onChange(of: focused) { _, v in
                    withAnimation(.easeOut(duration: 0.18)) { fieldFocused = v }
                }

            HStack {
                Spacer()
                Button("Annuler", action: onCancel)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Sauvegarder") {
                    onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .onAppear { focused = true }
    }
}
