import SwiftUI
import AppKit

/// The always-on overlay. Compact pill at rest; on hover it morphs
/// into the wider control bar via shared geometry — width / height /
/// corner-radius all animate from a single source so there's no fade
/// between two views.
struct OverlayView: View {
    @EnvironmentObject var timer: TimerState
    @EnvironmentObject var clickup: ClickUpService
    @EnvironmentObject var search: SearchController
    @EnvironmentObject var descCtl: DescriptionController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hovering = false
    @State private var hoverOutTask: Task<Void, Never>?
    @Namespace private var ns

    private var expanded: Bool { hovering || search.isOpen }

    /// Grace period before collapsing once the cursor leaves — long
    /// enough to forgive an accidental slide-off, short enough that
    /// the pill doesn't feel sticky once you're done with it.
    private let hoverOutDelay: UInt64 = 600_000_000  // 600ms

    // Layout constants
    private let compactWidth: CGFloat = 96
    private let compactHeight: CGFloat = 24
    private let expandedWidth: CGFloat = 352
    private let expandedHeight: CGFloat = 36

    private var morphSpring: Animation {
        reduceMotion
            ? .linear(duration: 0.18)
            : .interactiveSpring(response: 0.42, dampingFraction: 0.82,
                                 blendDuration: 0.2)
    }

    var body: some View {
        pill
            .frame(width: OverlayPanel.panelSize.width, height: 44, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 1)
    }

    // MARK: - Morphing pill

    private var pill: some View {
        let w = expanded ? expandedWidth : compactWidth
        let h = expanded ? expandedHeight : compactHeight

        return ZStack {
            // Background carries the shadow on its own layer so the
            // .clipShape applied to the content (next layer) can't crop it.
            pillShape
                .fill(.ultraThinMaterial)
                .shadow(
                    color: .black.opacity(expanded ? 0.32 : 0.20),
                    radius: expanded ? 18 : 9,
                    y: expanded ? 7 : 4
                )

            // Content — clipped to the pill so transitioning buttons
            // can't bleed outside the background mid-animation.
            content
                .clipShape(pillShape)

            pillShape
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)

            runningGlow.allowsHitTesting(false)
        }
        .frame(width: w, height: h)
        .scaleEffect(hovering && !reduceMotion ? 1.025 : 1.0)
        .opacity(idleOpacity)
        .contentShape(pillShape)
        .cursor(.pointingHand)
        .onHover { newValue in handleHover(newValue) }
    }

    private var content: some View {
        HStack(spacing: expanded ? 9 : 7) {
            statusDot

            Text(timer.formatted)
                .font(.system(
                    size: expanded ? 14 : 12,
                    weight: timer.isRunning ? .semibold : .medium,
                    design: .monospaced
                ))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .opacity(expanded ? 1 : 0.94)
                .matchedGeometryEffect(id: "time", in: ns)

            if expanded {
                Divider()
                    .frame(height: 18)
                    .opacity(0.35)
                    .transition(.opacity)

                taskLabel
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .move(edge: .leading))
                            .animation(morphSpring.delay(0.04)),
                        removal: .opacity
                    ))

                Spacer(minLength: 0)

                if timer.isRunning {
                    descriptionButton
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6)
                                .combined(with: .opacity)
                                .animation(morphSpring.delay(0.045)),
                            removal: .opacity
                        ))
                }

                searchButton
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6)
                            .combined(with: .opacity)
                            .animation(morphSpring.delay(0.06)),
                        removal: .opacity
                    ))

                startStopButton
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6)
                            .combined(with: .opacity)
                            .animation(morphSpring.delay(0.07)),
                        removal: .opacity
                    ))
            }
        }
        .padding(.horizontal, expanded ? 8 : 7)
        .padding(.vertical, 5)
    }

    private func handleHover(_ newValue: Bool) {
        // Re-entering inside the delay window cancels the pending
        // close, so a brief slide-off doesn't make the pill flash.
        hoverOutTask?.cancel()
        if newValue {
            withAnimation(morphSpring) { hovering = true }
        } else {
            hoverOutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: hoverOutDelay)
                if Task.isCancelled { return }
                withAnimation(morphSpring) { hovering = false }
            }
        }
    }

    private var pillShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: expanded ? 18 : compactHeight / 2,
            style: .continuous
        )
    }

    /// Subtle, state-aware opacity at rest. Even subtler when no timer
    /// is running — basically ambient — and a touch more present when
    /// it is, so a quick glance tells the user "time is being tracked".
    private var idleOpacity: Double {
        if expanded { return 1 }
        return timer.isRunning ? 0.82 : 0.42
    }

    /// Faint reddish ring around the pill while a timer runs — strong
    /// enough to read at a glance, weak enough to disappear visually
    /// when nothing else is going on.
    @ViewBuilder
    private var runningGlow: some View {
        if timer.isRunning {
            RoundedRectangle(
                cornerRadius: expanded ? 18 : compactHeight / 2,
                style: .continuous
            )
            .strokeBorder(Color.red.opacity(expanded ? 0.16 : 0.22),
                          lineWidth: 0.8)
            .blur(radius: 0.6)
            .transition(.opacity)
        }
    }

    // MARK: - Compact / expanded controls

    private var statusDot: some View {
        StatusDot(isRunning: timer.isRunning, reduceMotion: reduceMotion)
    }

    private var startStopButton: some View {
        StartStopButton(isRunning: timer.isRunning) { timer.toggle() }
    }

    // MARK: - Expanded-only elements

    @ViewBuilder
    private var taskLabel: some View {
        if let task = timer.currentTask {
            AssignedTaskButton(task: task) { openSearch() }
        } else {
            NoTaskButton(active: search.isOpen) { openSearch() }
        }
    }

    private var searchButton: some View {
        SearchPillButton(active: search.isOpen) { openSearch() }
    }

    private var descriptionButton: some View {
        DescriptionPillButton(
            active: descCtl.isOpen,
            hasContent: !timer.taskDescription.isEmpty
        ) {
            guard let panel = OverlayPanel.current else { return }
            descCtl.toggle(anchor: panel.frame, initial: timer.taskDescription)
        }
    }

    private func openSearch() {
        guard let panel = OverlayPanel.current else { return }
        search.toggle(anchor: panel.frame)
    }
}

// MARK: - Assigned task — clickable to swap via the search popover

private struct AssignedTaskButton: View {
    let task: ClickUpTask
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(task.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let list = task.listName {
                    Text(list)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 130, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Changer de tâche")
        .accessibilityLabel("Changer de tâche : \(task.name)")
        .onHover { v in
            withAnimation(.easeOut(duration: 0.14)) { hovering = v }
        }
    }
}

// MARK: - "Aucune tâche" affordance — also opens the search

private struct NoTaskButton: View {
    let active: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: hovering || active
                      ? "plus.circle.fill" : "plus.circle")
                    .font(.system(size: 11, weight: .medium))
                Text("Aucune tâche")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(
                active || hovering
                    ? Color.primary
                    : Color.secondary
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(hovering || active ? 0.10 : 0))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        Color.primary.opacity(active || hovering ? 0.20 : 0),
                        lineWidth: active || hovering ? 0.8 : 0
                    )
            )
            .scaleEffect(pressed ? 0.96 : 1.0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Lier une tâche ClickUp")
        .accessibilityLabel("Lier une tâche ClickUp")
        .onHover { v in
            withAnimation(.easeOut(duration: 0.15)) { hovering = v }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        withAnimation(.easeOut(duration: 0.06)) { pressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(
                        .interactiveSpring(response: 0.25, dampingFraction: 0.7)
                    ) { pressed = false }
                }
        )
    }
}

// MARK: - Status dot (pulsing breath when running)

private struct StatusDot: View {
    let isRunning: Bool
    let reduceMotion: Bool
    @State private var breath = false

    var body: some View {
        ZStack {
            if isRunning {
                Circle()
                    .fill(Color.red.opacity(0.35))
                    .frame(width: 12, height: 12)
                    .scaleEffect(breath ? 1.0 : 0.6)
                    .opacity(breath ? 0 : 0.7)
            }
            Circle()
                .fill(isRunning ? Color.red : Color.white.opacity(0.35))
                .frame(width: 6, height: 6)
                .shadow(color: isRunning ? .red.opacity(0.6) : .clear,
                        radius: 3, y: 0)
        }
        .frame(width: 12, height: 12)
        .onChange(of: isRunning) { _, running in
            updateBreath(running: running)
        }
        .onAppear { updateBreath(running: isRunning) }
        .accessibilityLabel(isRunning ? "Timer en cours" : "Timer arrêté")
    }

    private func updateBreath(running: Bool) {
        guard !reduceMotion else { breath = false; return }
        if running {
            withAnimation(
                .easeInOut(duration: 1.6).repeatForever(autoreverses: false)
            ) {
                breath = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { breath = false }
        }
    }
}

// MARK: - Start/Stop button (with press feedback)

private struct StartStopButton: View {
    let isRunning: Bool
    let action: () -> Void
    @State private var pressed = false
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(isRunning ? runningGradient : startGradient)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                )
                .shadow(
                    color: (isRunning ? Color.red : Color.green)
                        .opacity(pressed ? 0.15 : (hovering ? 0.45 : 0.32)),
                    radius: pressed ? 3 : (hovering ? 8 : 6),
                    y: pressed ? 1 : 2
                )
                .scaleEffect(pressed ? 0.92 : (hovering ? 1.04 : 1.0))
        }
        .buttonStyle(.plain)
        .help(isRunning ? "Arrêter le timer" : "Démarrer le timer")
        .accessibilityLabel(isRunning ? "Arrêter le timer" : "Démarrer le timer")
        .onHover { v in
            withAnimation(.easeOut(duration: 0.15)) { hovering = v }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(
                        .interactiveSpring(response: 0.25, dampingFraction: 0.6)
                    ) { pressed = false }
                }
        )
    }

    private var runningGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 1.0, green: 0.30, blue: 0.32),
                     Color(red: 0.86, green: 0.18, blue: 0.22)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var startGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.22, green: 0.80, blue: 0.44),
                     Color(red: 0.14, green: 0.62, blue: 0.34)],
            startPoint: .top, endPoint: .bottom
        )
    }
}

// MARK: - Description pill button

private struct DescriptionPillButton: View {
    let active: Bool
    let hasContent: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    private var iconName: String {
        hasContent ? "text.bubble.fill" : "text.bubble"
    }

    private var tint: Color {
        if active { return .accentColor }
        if hasContent { return .accentColor.opacity(0.85) }
        return .primary.opacity(0.85)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(.thickMaterial)
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            active
                                ? Color.accentColor.opacity(0.55)
                                : (hasContent
                                    ? Color.accentColor.opacity(0.30)
                                    : Color.white.opacity(hovering ? 0.22 : 0.12)),
                            lineWidth: active ? 1 : 0.5
                        )
                )
                .scaleEffect(pressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .help(hasContent ? "Modifier la description" : "Ajouter une description")
        .accessibilityLabel(
            hasContent ? "Modifier la description" : "Ajouter une description"
        )
        .onHover { v in
            withAnimation(.easeOut(duration: 0.15)) { hovering = v }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(
                        .interactiveSpring(response: 0.25, dampingFraction: 0.6)
                    ) { pressed = false }
                }
        )
    }
}

// MARK: - Search pill button

private struct SearchPillButton: View {
    let active: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : .primary.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(.thickMaterial)
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            active
                                ? Color.accentColor.opacity(0.55)
                                : Color.white.opacity(hovering ? 0.22 : 0.12),
                            lineWidth: active ? 1 : 0.5
                        )
                )
                .scaleEffect(pressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .help("Rechercher une tâche ClickUp")
        .accessibilityLabel("Rechercher une tâche ClickUp")
        .onHover { v in
            withAnimation(.easeOut(duration: 0.15)) { hovering = v }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(
                        .interactiveSpring(response: 0.25, dampingFraction: 0.6)
                    ) { pressed = false }
                }
        )
    }
}
