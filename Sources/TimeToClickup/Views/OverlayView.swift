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
    @EnvironmentObject var calendar: CalendarSyncCoordinator
    @EnvironmentObject var idleAlert: IdleAlertState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hovering = false
    @State private var hoverOutTask: Task<Void, Never>?
    @State private var showBackdateSheet = false
    @Namespace private var ns

    private var expanded: Bool { hovering || search.isOpen }
    private var alertActive: Bool { idleAlert.isAlertActive }

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
        Group {
            if idleAlert.isEndOfDayAlertActive {
                EndOfDayAlertPill(idleAlert: idleAlert, timer: timer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 2)
            } else if alertActive {
                IdleAlertPill(idleAlert: idleAlert, timer: timer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 2)
            } else {
                pill
                    .frame(width: OverlayPanel.normalSize.width, height: 44, alignment: .top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 1)
            }
        }
        .sheet(isPresented: $showBackdateSheet) {
            CustomBackdateSheet(timer: timer, isPresented: $showBackdateSheet)
        }
    }

    // MARK: - Morphing pill

    private var pill: some View {
        let w = expanded ? expandedWidth : compactWidth
        let h = expanded ? expandedHeight : compactHeight

        return ZStack {
            // Background — material only, no drop shadow (the border
            // and the glass material already give enough separation).
            pillShape
                .fill(.ultraThinMaterial)

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

                    calendarButton
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6)
                                .combined(with: .opacity)
                                .animation(morphSpring.delay(0.05)),
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
        StartStopButton(
            isRunning: timer.isRunning,
            onToggle: { timer.toggle() },
            onBackdate: { offset in timer.start(backdateBy: offset) },
            onCustomBackdate: { showBackdateSheet = true }
        )
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

    private var calendarButton: some View {
        CalendarPillButton(
            active: calendar.enabled,
            connected: GoogleAuthService.shared.isConnected,
            inProgress: calendar.hasActiveEvent
        ) {
            calendar.toggle()
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
    let onToggle: () -> Void
    let onBackdate: (TimeInterval) -> Void
    let onCustomBackdate: () -> Void
    @State private var pressed = false
    @State private var hovering = false
    @State private var chevronHovering = false

    var body: some View {
        HStack(spacing: 3) {
            mainButton
            if !isRunning { chevronButton }
        }
    }

    private var mainButton: some View {
        Button(action: onToggle) {
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

    /// Tiny dropdown chevron docked next to the play button (only when
    /// the timer isn't running). Opens a menu of backdate presets so
    /// the user can start a timer "il y a X minutes" without leaving
    /// the pill.
    private var chevronButton: some View {
        Menu {
            Button("Démarrer maintenant") { onBackdate(0) }
            Section("Démarrer il y a…") {
                Button("5 minutes") { onBackdate(5 * 60) }
                Button("10 minutes") { onBackdate(10 * 60) }
                Button("15 minutes") { onBackdate(15 * 60) }
                Button("30 minutes") { onBackdate(30 * 60) }
                Button("1 heure") { onBackdate(60 * 60) }
            }
            Button("Heure précise…") { onCustomBackdate() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 26)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.62, blue: 0.34),
                            Color(red: 0.12, green: 0.50, blue: 0.28)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
                )
                .overlay(
                    Capsule().strokeBorder(
                        Color.white.opacity(0.22), lineWidth: 0.5
                    )
                )
                .scaleEffect(chevronHovering ? 1.06 : 1.0)
                .shadow(
                    color: Color.green.opacity(chevronHovering ? 0.40 : 0.24),
                    radius: chevronHovering ? 6 : 4, y: 1.5
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Démarrer le timer à une date antérieure")
        .accessibilityLabel("Démarrer le timer à une date antérieure")
        .onHover { v in
            withAnimation(.easeOut(duration: 0.15)) { chevronHovering = v }
        }
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

// MARK: - Calendar pill button (toggles Google Calendar sync)

private struct CalendarPillButton: View {
    let active: Bool
    let connected: Bool
    let inProgress: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    private var iconName: String {
        if !connected { return "calendar.badge.exclamationmark" }
        if active && inProgress { return "calendar.badge.clock" }
        if active { return "calendar.circle.fill" }
        return "calendar"
    }

    private var tint: Color {
        if !connected { return .secondary }
        if active { return .accentColor }
        return .primary.opacity(0.85)
    }

    private var help: String {
        if !connected {
            return "Connecte Google Calendar dans les Settings"
        }
        if active {
            return inProgress
                ? "Sync calendrier active — event en cours"
                : "Sync calendrier active — désactiver"
        }
        return "Activer la sync Google Calendar"
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.thickMaterial))
                    .overlay(
                        Circle().strokeBorder(
                            active
                                ? Color.accentColor.opacity(0.55)
                                : Color.white.opacity(hovering ? 0.22 : 0.12),
                            lineWidth: active ? 1 : 0.5
                        )
                    )

                if inProgress {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                        .offset(x: 1, y: -1)
                }
            }
            .scaleEffect(pressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!connected)
        .help(help)
        .accessibilityLabel(help)
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

// MARK: - Idle alert pill ("Tu as oublié le timer")

/// Replaces the regular pill when no timer has been running for the
/// configured idle threshold. Yellow on black, pulsing, with two
/// dropdown actions: start (with optional backdate) or snooze.
private struct IdleAlertPill: View {
    @ObservedObject var idleAlert: IdleAlertState
    @ObservedObject var timer: TimerState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    @State private var customSnoozeOpen = false
    @State private var customBackdateOpen = false

    /// Yellow petant accent for the alert. Tuned so the border reads
    /// instantly without going neon-toy.
    private static let accent = Color(red: 1.0, green: 0.86, blue: 0.10)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Self.accent)
                .shadow(color: Self.accent.opacity(0.55), radius: 4)

            Text("Tu as oublié le timer")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 6)

            startMenu
            snoozeMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 444, height: 44)
        .background(shape.fill(.ultraThinMaterial))
        // Soft yellow inner wash so the material reads warmer without
        // smothering the glass texture.
        .overlay(
            shape.fill(Self.accent.opacity(pulsing ? 0.10 : 0.06))
                 .allowsHitTesting(false)
        )
        // The yellow petant border itself — thicker than a normal pill
        // border, a touch more saturated when pulsing.
        .overlay(
            shape.strokeBorder(
                Self.accent.opacity(pulsing ? 1.0 : 0.85),
                lineWidth: 1.6
            )
        )
        .scaleEffect(pulsing && !reduceMotion ? 1.012 : 1.0)
        .shadow(
            color: Self.accent.opacity(pulsing ? 0.18 : 0.08),
            radius: pulsing ? 6 : 3, y: 1
        )
        .onAppear { startPulse() }
        .sheet(isPresented: $customSnoozeOpen) {
            CustomSnoozeSheet(idleAlert: idleAlert,
                              isPresented: $customSnoozeOpen)
        }
        .sheet(isPresented: $customBackdateOpen) {
            CustomBackdateSheet(timer: timer,
                                isPresented: $customBackdateOpen)
        }
    }

    private func startPulse() {
        guard !reduceMotion else { return }
        withAnimation(
            .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
        ) {
            pulsing = true
        }
    }

    private var startMenu: some View {
        Menu {
            Button("Démarrer maintenant") {
                timer.start(backdateBy: 0)
            }
            Section("Démarrer il y a…") {
                Button("5 minutes") { timer.start(backdateBy: 5 * 60) }
                Button("10 minutes") { timer.start(backdateBy: 10 * 60) }
                Button("15 minutes") { timer.start(backdateBy: 15 * 60) }
                Button("30 minutes") { timer.start(backdateBy: 30 * 60) }
                Button("1 heure") { timer.start(backdateBy: 60 * 60) }
            }
            Button("Heure précise…") { customBackdateOpen = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Démarrer")
                    .font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [
                        Color(red: 0.22, green: 0.80, blue: 0.44),
                        Color(red: 0.14, green: 0.62, blue: 0.34)
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            )
            .overlay(
                Capsule().strokeBorder(
                    Color.white.opacity(0.22), lineWidth: 0.5
                )
            )
            .shadow(color: Color.green.opacity(0.30), radius: 5, y: 1.5)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Démarrer le timer (avec l'option de backdater)")
    }

    private var snoozeMenu: some View {
        Menu {
            Section("Mettre en sourdine pendant…") {
                Button("5 minutes") { idleAlert.snooze(for: 5 * 60) }
                Button("15 minutes") { idleAlert.snooze(for: 15 * 60) }
                Button("30 minutes") { idleAlert.snooze(for: 30 * 60) }
                Button("1 heure") { idleAlert.snooze(for: 60 * 60) }
            }
            Button("Jusqu'à la fin de la journée") {
                idleAlert.snoozeUntilEndOfDay()
            }
            Button("Jusqu'à une heure précise…") {
                customSnoozeOpen = true
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Plus tard")
                    .font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule().strokeBorder(
                    Color.primary.opacity(0.22), lineWidth: 0.5
                )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mettre l'alerte en sourdine")
    }
}

// MARK: - End of day alert pill (red, "stop the timer")

/// Sister of IdleAlertPill but red. Shown when the timer is still
/// running past the user's configured end of work day.
private struct EndOfDayAlertPill: View {
    @ObservedObject var idleAlert: IdleAlertState
    @ObservedObject var timer: TimerState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private static let accent = Color(red: 1.0, green: 0.28, blue: 0.30)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return HStack(spacing: 10) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Self.accent)
                .shadow(color: Self.accent.opacity(0.55), radius: 4)

            Text("Fin de journée — pense au timer")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 6)

            stopButton
            snoozeMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 444, height: 44)
        .background(shape.fill(.ultraThinMaterial))
        .overlay(
            shape.fill(Self.accent.opacity(pulsing ? 0.10 : 0.06))
                 .allowsHitTesting(false)
        )
        .overlay(
            shape.strokeBorder(
                Self.accent.opacity(pulsing ? 1.0 : 0.85),
                lineWidth: 1.6
            )
        )
        .scaleEffect(pulsing && !reduceMotion ? 1.012 : 1.0)
        .shadow(
            color: Self.accent.opacity(pulsing ? 0.18 : 0.08),
            radius: pulsing ? 6 : 3, y: 1
        )
        .onAppear { startPulse() }
    }

    private func startPulse() {
        guard !reduceMotion else { return }
        withAnimation(
            .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
        ) {
            pulsing = true
        }
    }

    private var stopButton: some View {
        Button {
            timer.stop()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Arrêter")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [
                        Color(red: 1.0, green: 0.30, blue: 0.32),
                        Color(red: 0.86, green: 0.18, blue: 0.22)
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
            )
            .overlay(
                Capsule().strokeBorder(
                    Color.white.opacity(0.22), lineWidth: 0.5
                )
            )
            .shadow(color: Self.accent.opacity(0.30), radius: 5, y: 1.5)
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help("Arrêter le timer maintenant")
    }

    private var snoozeMenu: some View {
        Menu {
            Section("Continuer encore…") {
                Button("15 minutes") { idleAlert.snoozeEndOfDay(for: 15 * 60) }
                Button("30 minutes") { idleAlert.snoozeEndOfDay(for: 30 * 60) }
                Button("1 heure") { idleAlert.snoozeEndOfDay(for: 60 * 60) }
                Button("2 heures") { idleAlert.snoozeEndOfDay(for: 2 * 60 * 60) }
            }
            Button("Jusqu'à demain") {
                var c = Calendar.current.dateComponents(
                    [.year, .month, .day], from: Date()
                )
                c.hour = 23; c.minute = 59
                if let d = Calendar.current.date(from: c) {
                    idleAlert.snoozeEndOfDay(until: d)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Continuer")
                    .font(.system(size: 11.5, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .overlay(
                Capsule().strokeBorder(
                    Color.primary.opacity(0.22), lineWidth: 0.5
                )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mettre l'alerte de fin de journée en sourdine")
    }
}

// MARK: - Sheet primitives shared between custom backdate / snooze

/// Header bar: tinted icon + title + subtitle. Sets the tone of the
/// sheet so the user instantly knows what mode they're in.
private struct SheetHeader: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.22), tint.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 38, height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(tint.opacity(0.25), lineWidth: 0.6)
                    )
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// One quick-pick chip. Modern hover scale, fast color transitions,
/// pointing-hand cursor. `selectedForeground` lets callers pick a
/// dark text for light tints (yellow → black instead of white).
private struct QuickChip: View {
    let label: String
    let tint: Color
    let selected: Bool
    var selectedForeground: Color = .white
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    selected ? selectedForeground : .primary.opacity(0.88)
                )
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(
                        selected
                            ? AnyShapeStyle(LinearGradient(
                                colors: [tint, tint.opacity(0.85)],
                                startPoint: .top, endPoint: .bottom
                            ))
                            : AnyShapeStyle(
                                Color.primary.opacity(hovering ? 0.12 : 0.06)
                            )
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        selected
                            ? tint.opacity(0.55)
                            : Color.primary.opacity(hovering ? 0.18 : 0.10),
                        lineWidth: 0.7
                    )
                )
                .shadow(
                    color: selected ? tint.opacity(0.28) : .clear,
                    radius: 6, y: 2
                )
                .scaleEffect(hovering && !selected ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { v in
            withAnimation(.easeOut(duration: 0.14)) { hovering = v }
        }
    }
}

/// Section wrapper: small uppercase caption + content card with a
/// subtle quaternary background to separate it from the sheet body.
private struct SheetSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
            content
        }
    }
}

/// A "preview" line shown in the footer (icon + descriptive text)
/// that confirms the user's current selection at a glance.
private struct SheetPreview: View {
    let icon: String
    let tint: Color
    let prefix: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            (
                Text(prefix)
                    .foregroundStyle(.secondary)
                +
                Text(value)
                    .foregroundStyle(.primary)
                    .fontWeight(.semibold)
            )
            .font(.system(size: 12.5))
        }
    }
}

/// Sheet primary action button — modern, with hover/press feedback
/// and a pointing-hand cursor. `foreground` defaults to white but can
/// be overridden when the tint is too light for white text (e.g. the
/// yellow snooze button reads better with black).
private struct SheetPrimaryButton: View {
    let title: String
    let tint: Color
    var foreground: Color = .white
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    private var borderOpacity: Double {
        // Light tints get a darker border for definition; dark tints
        // get a white-ish highlight. Heuristic: high green channel ≈
        // light tint.
        foreground == .black ? 0.18 : 0.22
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: [tint, tint.opacity(0.86)],
                        startPoint: .top, endPoint: .bottom
                    ))
                )
                .overlay(
                    Capsule().strokeBorder(
                        (foreground == .black ? Color.black : Color.white)
                            .opacity(borderOpacity),
                        lineWidth: 0.6
                    )
                )
                .shadow(
                    color: tint.opacity(pressed ? 0.18 : (hovering ? 0.45 : 0.28)),
                    radius: pressed ? 3 : (hovering ? 9 : 6), y: 2
                )
                .scaleEffect(pressed ? 0.97 : (hovering ? 1.025 : 1.0))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .cursor(.pointingHand)
        .onHover { v in
            withAnimation(.easeOut(duration: 0.14)) { hovering = v }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        withAnimation(.easeOut(duration: 0.06)) { pressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.18)) { pressed = false }
                }
        )
    }
}

/// Sheet secondary action (Cancel) — clean, hover background only.
private struct SheetSecondaryButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(
                        Color.primary.opacity(hovering ? 0.10 : 0.05)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        Color.primary.opacity(hovering ? 0.18 : 0.10),
                        lineWidth: 0.6
                    )
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .cursor(.pointingHand)
        .onHover { v in
            withAnimation(.easeOut(duration: 0.14)) { hovering = v }
        }
    }
}

/// Time card: clickable hour & minute segments separated by ":". Each
/// segment opens a popover listing valid values. Up/down chevrons on
/// the side fine-tune by 5-minute steps.
private struct TimeCard: View {
    @Binding var date: Date
    let allowFuture: Bool
    let tint: Color

    @State private var hourPopoverOpen = false
    @State private var minutePopoverOpen = false

    private var hour: Int {
        Calendar.current.component(.hour, from: date)
    }
    private var minute: Int {
        Calendar.current.component(.minute, from: date)
    }

    private func setHour(_ h: Int) {
        var c = Calendar.current.dateComponents(
            [.year, .month, .day, .minute, .second], from: date
        )
        c.hour = ((h % 24) + 24) % 24
        if let d = Calendar.current.date(from: c) {
            date = allowFuture ? d : min(d, Date())
        }
    }
    private func setMinute(_ m: Int) {
        var c = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .second], from: date
        )
        c.minute = ((m % 60) + 60) % 60
        if let d = Calendar.current.date(from: c) {
            date = allowFuture ? d : min(d, Date())
        }
    }
    private func bump(_ minutes: Int) {
        let new = date.addingTimeInterval(TimeInterval(minutes) * 60)
        date = allowFuture ? new : min(new, Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                TimeSegment(
                    value: hour, tint: tint,
                    isOpen: $hourPopoverOpen
                ) {
                    ValueListPopover(
                        values: Array(0...23), current: hour,
                        formatter: { String(format: "%02d", $0) },
                        tint: tint
                    ) { v in
                        setHour(v)
                        hourPopoverOpen = false
                    }
                }

                Text(":")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 1)

                TimeSegment(
                    value: minute, tint: tint,
                    isOpen: $minutePopoverOpen
                ) {
                    // Step minutes by 1 in the picker so people can hit
                    // arbitrary HH:MM values; the chevrons cover the
                    // common ±5 min adjustments.
                    ValueListPopover(
                        values: Array(0..<60), current: minute,
                        formatter: { String(format: "%02d", $0) },
                        tint: tint
                    ) { v in
                        setMinute(v)
                        minutePopoverOpen = false
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.6)
            )

            VStack(spacing: 4) {
                StepArrow(symbol: "chevron.up", tint: tint) { bump(+5) }
                StepArrow(symbol: "chevron.down", tint: tint) { bump(-5) }
            }

            Text("± 5 min")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
    }
}

/// One clickable HH or MM segment. Highlights on hover, opens its
/// popover on click.
private struct TimeSegment<PopoverContent: View>: View {
    let value: Int
    let tint: Color
    @Binding var isOpen: Bool
    @ViewBuilder var popoverContent: () -> PopoverContent
    @State private var hovering = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            Text(String(format: "%02d", value))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(hovering || isOpen ? tint : .primary)
                .frame(width: 38)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            (hovering || isOpen)
                                ? tint.opacity(0.12)
                                : Color.clear
                        )
                )
                .contentTransition(.numericText(value: Double(value)))
                .animation(.easeOut(duration: 0.12), value: value)
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { v in
            withAnimation(.easeOut(duration: 0.12)) { hovering = v }
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            popoverContent()
        }
    }
}

/// Scrollable list of values (used by both hour and minute popovers).
/// Pre-scrolls to the current selection so the user lands near it.
private struct ValueListPopover: View {
    let values: [Int]
    let current: Int
    let formatter: (Int) -> String
    let tint: Color
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(values, id: \.self) { v in
                        ValueRow(
                            label: formatter(v),
                            tint: tint,
                            selected: v == current
                        ) { onPick(v) }
                            .id(v)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 96, height: 220)
            .onAppear {
                // Center the current value in the visible window.
                proxy.scrollTo(current, anchor: .center)
            }
        }
    }
}

private struct ValueRow: View {
    let label: String
    let tint: Color
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular,
                                  design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? .white : .primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        selected
                            ? AnyShapeStyle(tint)
                            : AnyShapeStyle(
                                Color.primary.opacity(hovering ? 0.10 : 0)
                            )
                    )
            )
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { v in
            withAnimation(.easeOut(duration: 0.10)) { hovering = v }
        }
    }
}

private struct StepArrow: View {
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? tint : .secondary)
                .frame(width: 24, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.12 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(hovering ? 0.20 : 0.10),
                            lineWidth: 0.6
                        )
                )
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { v in
            withAnimation(.easeOut(duration: 0.12)) { hovering = v }
        }
    }
}

// MARK: - Custom backdate sheet (start a timer at a past time)

private struct CustomBackdateSheet: View {
    @ObservedObject var timer: TimerState
    @Binding var isPresented: Bool

    @State private var recentMeetings: [GoogleCalendarService.Meeting] = []
    @State private var meetingsLoading = false

    /// Default: now − 30 minutes, rounded down to the nearest 5.
    @State private var startTime: Date = {
        let past = Date().addingTimeInterval(-30 * 60)
        let cal = Calendar.current
        var comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute], from: past
        )
        if let m = comps.minute { comps.minute = (m / 5) * 5 }
        return cal.date(from: comps) ?? past
    }()

    private static let tint = Color(red: 0.18, green: 0.62, blue: 0.34)
    private let presetMinutes: [Int] = [5, 10, 15, 30, 45, 60]

    private var elapsedSeconds: TimeInterval {
        max(0, Date().timeIntervalSince(startTime))
    }

    private var elapsedLabel: String {
        let m = Int(elapsedSeconds / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60
        let r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    private var startLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: startTime)
    }

    private var matchingPreset: Int? {
        let m = Int(elapsedSeconds / 60)
        return presetMinutes.first(where: { $0 == m })
    }

    private func applyPreset(_ minutes: Int) {
        startTime = Date().addingTimeInterval(-Double(minutes) * 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeader(
                icon: "clock.arrow.circlepath",
                tint: Self.tint,
                title: "Démarrer à une heure antérieure",
                subtitle: "Le timer démarrera avec du temps déjà écoulé."
            )

            SheetSection(title: "Raccourcis") {
                HStack(spacing: 8) {
                    ForEach(presetMinutes, id: \.self) { m in
                        QuickChip(
                            label: "\(m) min",
                            tint: Self.tint,
                            selected: matchingPreset == m
                        ) { applyPreset(m) }
                    }
                }
            }

            HStack(alignment: .top, spacing: 14) {
                SheetSection(title: "Heure exacte") {
                    TimeCard(
                        date: $startTime,
                        allowFuture: false,
                        tint: Self.tint
                    )
                }

                if !recentMeetings.isEmpty || meetingsLoading {
                    OrSeparator()
                    SheetSection(title: meetingsLoading
                                 ? "Réunions récentes…"
                                 : "Après une réunion") {
                        VStack(alignment: .leading, spacing: 6) {
                            if meetingsLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.vertical, 4)
                            }
                            ForEach(recentMeetings.prefix(3)) { meeting in
                                EndedMeetingButton(meeting: meeting) {
                                    let offset = max(
                                        0,
                                        Date().timeIntervalSince(meeting.end)
                                    )
                                    timer.start(backdateBy: offset)
                                    isPresented = false
                                }
                            }
                        }
                    }
                }
            }

            Divider().opacity(0.4).padding(.vertical, 2)

            HStack(spacing: 14) {
                SheetPreview(
                    icon: "play.circle.fill",
                    tint: Self.tint,
                    prefix: "Démarre à ",
                    value: "\(startLabel)  ·  \(elapsedLabel) écoulées"
                )
                Spacer()
                SheetSecondaryButton(title: "Annuler") { isPresented = false }
                SheetPrimaryButton(
                    title: "Démarrer le timer",
                    tint: Self.tint
                ) {
                    timer.start(backdateBy: elapsedSeconds)
                    isPresented = false
                }
            }
        }
        .padding(24)
        .frame(width: recentMeetings.isEmpty && !meetingsLoading ? 460 : 580)
        .animation(.easeOut(duration: 0.18), value: recentMeetings.count)
        .task { await loadMeetings() }
    }

    private func loadMeetings() async {
        guard GoogleAuthService.shared.isConnected else { return }
        meetingsLoading = true
        do {
            let m = try await GoogleCalendarService.shared
                .recentlyEndedMeetings()
            self.recentMeetings = m
        } catch {
            LogStore.shared.warn(
                "📅 Réunions récentes non chargées : \(error.localizedDescription)"
            )
        }
        meetingsLoading = false
    }
}

/// Same look as `MeetingButton` but for *ended* meetings — the caller
/// uses this in the backdate sheet to start the timer at the moment a
/// past meeting ended.
private struct EndedMeetingButton: View {
    let meeting: GoogleCalendarService.Meeting
    let action: () -> Void
    @State private var hovering = false

    private var endLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: meeting.end)
    }

    private var sinceLabel: String {
        let mins = max(0, Int(Date().timeIntervalSince(meeting.end) / 60))
        if mins < 60 { return "il y a \(mins) min" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "il y a \(h) h" : "il y a \(h) h \(m) min"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Finie à \(endLabel) · \(sinceLabel)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.5)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(width: 240, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(hovering ? 0.32 : 0.18),
                        lineWidth: 0.7
                    )
            )
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help("Démarrer le timer à la fin de « \(meeting.summary) »")
        .onHover { v in
            withAnimation(.easeOut(duration: 0.14)) { hovering = v }
        }
    }
}

// MARK: - Custom snooze sheet (until HH:MM)

private struct CustomSnoozeSheet: View {
    @ObservedObject var idleAlert: IdleAlertState
    @Binding var isPresented: Bool

    @State private var ongoingMeetings: [GoogleCalendarService.Meeting] = []
    @State private var meetingsLoading = false

    @State private var target: Date = {
        // Default: now + 1h, rounded to the next 5 minutes for tidy UI.
        let plusHour = Date().addingTimeInterval(3600)
        let cal = Calendar.current
        var comps = cal.dateComponents(
            [.year, .month, .day, .hour, .minute], from: plusHour
        )
        if let m = comps.minute { comps.minute = ((m + 4) / 5) * 5 }
        return cal.date(from: comps) ?? plusHour
    }()

    private static let tint = Color(red: 1.0, green: 0.78, blue: 0.10)
    private let presetMinutes: [Int] = [15, 30, 60, 120]

    private var resolvedTarget: Date {
        target <= Date() ? target.addingTimeInterval(24 * 3600) : target
    }

    private var deltaSeconds: TimeInterval {
        max(0, resolvedTarget.timeIntervalSince(Date()))
    }

    private var deltaLabel: String {
        let m = Int(deltaSeconds / 60)
        if m < 60 { return "\(m) min" }
        let h = m / 60
        let r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }

    private var targetLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: resolvedTarget)
    }

    private var matchingPreset: Int? {
        let m = Int(deltaSeconds / 60)
        return presetMinutes.first(where: { $0 == m })
    }

    private func applyPreset(_ minutes: Int) {
        target = Date().addingTimeInterval(Double(minutes) * 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SheetHeader(
                icon: "bell.slash.fill",
                tint: Self.tint,
                title: "Mettre l'alerte en sourdine",
                subtitle: "L'alerte ne reviendra pas avant l'heure choisie."
            )

            SheetSection(title: "Raccourcis") {
                HStack(spacing: 8) {
                    ForEach(presetMinutes, id: \.self) { m in
                        QuickChip(
                            label: m < 60 ? "\(m) min" : "\(m / 60) h",
                            tint: Self.tint,
                            selected: matchingPreset == m,
                            selectedForeground: .black
                        ) { applyPreset(m) }
                    }
                    QuickChip(
                        label: "Fin de journée",
                        tint: Self.tint,
                        selected: false,
                        selectedForeground: .black
                    ) {
                        var c = Calendar.current.dateComponents(
                            [.year, .month, .day], from: Date()
                        )
                        c.hour = 23; c.minute = 59
                        if let d = Calendar.current.date(from: c) {
                            target = d
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 14) {
                SheetSection(title: "Heure exacte") {
                    TimeCard(
                        date: $target,
                        allowFuture: true,
                        tint: Self.tint
                    )
                }

                if !ongoingMeetings.isEmpty || meetingsLoading {
                    OrSeparator()
                    SheetSection(title: meetingsLoading
                                 ? "Réunion en cours…"
                                 : "Fin d'une réunion") {
                        VStack(alignment: .leading, spacing: 6) {
                            if meetingsLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.vertical, 4)
                            }
                            ForEach(ongoingMeetings) { meeting in
                                MeetingButton(meeting: meeting) {
                                    idleAlert.snooze(until: meeting.end)
                                    isPresented = false
                                }
                            }
                        }
                    }
                }
            }

            Divider().opacity(0.4).padding(.vertical, 2)

            HStack(spacing: 14) {
                SheetPreview(
                    icon: "moon.zzz.fill",
                    tint: Self.tint,
                    prefix: "Réactive à ",
                    value: "\(targetLabel)  ·  dans \(deltaLabel)"
                )
                Spacer()
                SheetSecondaryButton(title: "Annuler") { isPresented = false }
                SheetPrimaryButton(
                    title: "Mettre en sourdine",
                    tint: Self.tint,
                    foreground: .black
                ) {
                    idleAlert.snooze(until: resolvedTarget)
                    isPresented = false
                }
            }
        }
        .padding(24)
        .frame(width: ongoingMeetings.isEmpty && !meetingsLoading ? 460 : 580)
        .animation(.easeOut(duration: 0.18), value: ongoingMeetings.count)
        .task { await loadMeetings() }
    }

    private func loadMeetings() async {
        guard GoogleAuthService.shared.isConnected else { return }
        meetingsLoading = true
        do {
            let m = try await GoogleCalendarService.shared.currentMeetings()
            self.ongoingMeetings = m
        } catch {
            // Silent — the section just stays hidden if anything fails.
            LogStore.shared.warn(
                "📅 Réunions en cours non chargées : \(error.localizedDescription)"
            )
        }
        meetingsLoading = false
    }
}

/// Vertical "OU" separator between the time picker and the meetings
/// shortcut. Keeps the two snooze paths visually equivalent so neither
/// reads as the only option.
private struct OrSeparator: View {
    var body: some View {
        VStack(spacing: 6) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            Text("OU")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    Capsule().fill(Color.primary.opacity(0.04))
                )
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 22)
        .padding(.top, 18)
    }
}

/// Subtle gray button (white border) that snoozes until the end of a
/// specific meeting. Shows the meeting title + end time.
private struct MeetingButton: View {
    let meeting: GoogleCalendarService.Meeting
    let action: () -> Void
    @State private var hovering = false

    private var endLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: meeting.end)
    }

    private var remainingLabel: String {
        let mins = max(0, Int(meeting.end.timeIntervalSinceNow / 60))
        if mins < 60 { return "\(mins) min restantes" }
        let h = mins / 60, m = mins % 60
        return m == 0 ? "\(h) h restantes" : "\(h) h \(m) min restantes"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Jusqu'à \(endLabel) · \(remainingLabel)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.5)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(width: 240, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(hovering ? 0.32 : 0.18),
                        lineWidth: 0.7
                    )
            )
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help("Mettre en sourdine jusqu'à la fin de « \(meeting.summary) »")
        .onHover { v in
            withAnimation(.easeOut(duration: 0.14)) { hovering = v }
        }
    }
}
