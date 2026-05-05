import SwiftUI
import AppKit

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "TimeToClickup"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 880, height: 760))
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var clickup = ClickUpService.shared
    @ObservedObject var google = GoogleAuthService.shared
    @ObservedObject var hours = WorkingHoursState.shared
    @ObservedObject var idleAlert = IdleAlertState.shared
    @ObservedObject var timer = TimerState.shared

    @State private var token: String =
        KeychainHelper.shared.get(key: "clickup_api_token") ?? ""
    @State private var tokenSaved = false

    @State private var googleClientId: String =
        GoogleAuthService.shared.clientId ?? ""
    @State private var googleClientSecret: String =
        GoogleAuthService.shared.clientSecret ?? ""

    @State private var tab: Tab = .clickup

    enum Tab: String, CaseIterable, Identifiable {
        case clickup, calendar, prefixes, hours, display, tests
        var id: String { rawValue }
        var label: String {
            switch self {
            case .clickup:  return "ClickUp"
            case .calendar: return "Calendrier"
            case .prefixes: return "Préfixes"
            case .hours:    return "Horaires"
            case .display:  return "Affichage"
            case .tests:    return "Tests"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                AlertStatusCard(
                    idleAlert: idleAlert,
                    timer: timer,
                    hours: hours
                )
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .clickup:
                            tokenSection
                            Divider()
                            spacesSection
                        case .calendar:
                            googleSection
                        case .prefixes:
                            prefixesSection
                        case .hours:
                            workingHoursSection
                        case .display:
                            displaySection
                        case .tests:
                            searchTestSection
                        }
                    }
                    .padding(20)
                }
            }
            .frame(width: 540)

            Divider()

            LogSidebarView()
                .frame(maxHeight: .infinity)
        }
        .frame(width: 880, height: 760)
        .onAppear {
            if clickup.availableSpaces.isEmpty && clickup.hasToken {
                Task { await clickup.loadAllSpaces() }
            }
        }
    }

    // MARK: - Search test (inline)

    @State private var testQuery = ""
    @State private var testResults: [ClickUpTask] = []
    @State private var testLoading = false
    @State private var testTask: Task<Void, Never>?
    @State private var testRanAt: Date?
    @State private var testIgnoreFilter = false

    private var searchTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Tester la recherche",
                      systemImage: "magnifyingglass.circle")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if testLoading { ProgressView().controlSize(.small) }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("ex: moment-effort", text: $testQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onChange(of: testQuery) { _, new in scheduleTest(new) }
                if !testQuery.isEmpty {
                    Button { testQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
            )

            HStack(spacing: 8) {
                Toggle(isOn: $testIgnoreFilter) {
                    Text("Ignorer la whitelist (toute l'API)")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .onChange(of: testIgnoreFilter) { _, _ in
                    scheduleTest(testQuery)
                }
                Spacer()
                Button {
                    Task { await clickup.dumpRawSearch(query: testQuery) }
                } label: {
                    Label("Dump réponse serveur", systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)
                .disabled(testQuery.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    Task { await clickup.inspectTask(urlOrId: testQuery) }
                } label: {
                    Label("Inspecter (URL/ID)", systemImage: "info.circle")
                }
                .controlSize(.small)
                .disabled(testQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            resultsView

            if let ts = testRanAt, !testQuery.isEmpty {
                Text("\(testResults.count) résultat(s) — \(ts.formatted(.dateTime.hour().minute().second()))" +
                     (testIgnoreFilter ? " (sans filtre)" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        if testQuery.isEmpty {
            Text("Tape une requête pour vérifier la whitelist en direct. " +
                 "Active « Ignorer la whitelist » pour vérifier où vit vraiment la tâche.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else if testResults.isEmpty && !testLoading {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text("Aucun résultat — vois les logs pour l'URL exacte.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(testResults.prefix(8)) { task in
                    resultRow(task)
                    Divider().opacity(0.2)
                }
                if testResults.count > 8 {
                    Text("+ \(testResults.count - 8) autre(s) — tronqué.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.04))
            )
        }
    }

    private func resultRow(_ task: ClickUpTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                let path = [task.spaceName, task.folderName, task.listName]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty && $0 != "hidden" }
                    .joined(separator: " › ")
                if !path.isEmpty {
                    Text(path)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func scheduleTest(_ q: String) {
        testTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            testResults = []
            testLoading = false
            return
        }
        testLoading = true
        let ignoreFilter = testIgnoreFilter
        testTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let r = await clickup.search(
                query: trimmed, ignoreWhitelist: ignoreFilter
            )
            if Task.isCancelled { return }
            await MainActor.run {
                self.testResults = r
                self.testLoading = false
                self.testRanAt = Date()
            }
        }
    }

    // MARK: - Token

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ClickUp Personal API Token", systemImage: "key.fill")
                .font(.system(size: 13, weight: .semibold))

            HStack {
                SecureField("pk_...", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                Button("Sauvegarder") { saveToken() }
                    .keyboardShortcut(.defaultAction)
            }

            HStack(spacing: 6) {
                if tokenSaved {
                    Label("Sauvegardé", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 11))
                        .transition(.opacity)
                }
                Spacer()
                Text("ClickUp → Settings → Apps → API Token")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveToken() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainHelper.shared.set(key: "clickup_api_token", value: trimmed)
        clickup.reset()
        withAnimation { tokenSaved = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { withAnimation { tokenSaved = false } }
            await clickup.loadAllSpaces()
        }
    }

    // MARK: - Google Calendar

    private var googleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Google Calendar", systemImage: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if google.isAuthorizing {
                    ProgressView().controlSize(.small)
                }
            }

            if google.isConnected {
                connectedRow
            } else if google.hasBundledCredentials {
                bundledConnectRow
            } else {
                credentialsForm
            }

            if let err = google.lastError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private var connectedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(google.connectedEmail ?? "—")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Déconnecter") { google.disconnect() }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    private var bundledConnectRow: some View {
        HStack(spacing: 8) {
            Image(systemName: google.isAuthorizing
                  ? "hourglass" : "link.circle")
                .foregroundStyle(.secondary)
            Text(google.isAuthorizing
                 ? "En attente de l'autorisation dans le navigateur…"
                 : "Synchronise tes timers ClickUp avec ton agenda Google.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if google.isAuthorizing {
                Button("Annuler") {
                    google.cancelAuthorization()
                }
                .controlSize(.small)
            } else {
                Button { connectGoogle() } label: {
                    Label("Connecter Google", systemImage: "link")
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Client ID")
                    .frame(width: 90, alignment: .trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("xxx.apps.googleusercontent.com",
                          text: $googleClientId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
            HStack {
                Text("Client secret")
                    .frame(width: 90, alignment: .trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                SecureField("GOCSPX-…", text: $googleClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
            HStack {
                Text("Console Google Cloud → Credentials → OAuth 2.0 Client ID type **Desktop app**. Active **Calendar API** + ajoute-toi en *test user* sur l'écran de consentement.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    connectGoogle()
                } label: {
                    Label("Connecter", systemImage: "link")
                }
                .controlSize(.small)
                .disabled(google.isAuthorizing
                          || googleClientId.isEmpty
                          || googleClientSecret.isEmpty)
            }
        }
    }

    private func connectGoogle() {
        if !google.hasBundledCredentials {
            google.setCredentials(
                clientId: googleClientId,
                clientSecret: googleClientSecret
            )
        }
        google.lastError = nil
        Task {
            do { try await google.connect() }
            catch {
                if !(error is CancellationError) {
                    google.lastError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Spaces / Folders whitelist

    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Espaces & sous-espaces à inclure",
                      systemImage: "square.stack.3d.up")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if clickup.loadingSpaces {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await clickup.loadAllSpaces() }
                } label: {
                    Label("Recharger", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(!clickup.hasToken || clickup.loadingSpaces)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if clickup.availableSpaces.isEmpty {
                        emptyState
                    } else {
                        ForEach(clickup.availableSpaces) { space in
                            SpaceRow(space: space)
                            Divider().padding(.leading, 14).opacity(0.3)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.04))
            )

            footer
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: clickup.hasToken
                  ? "tray" : "key.slash")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(clickup.hasToken
                 ? (clickup.loadingSpaces
                    ? "Chargement des espaces…"
                    : "Aucun espace — clique « Recharger »")
                 : "Saisis ton token ClickUp pour charger les espaces.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var footer: some View {
        HStack {
            let total = clickup.selectedSpaceIds.count
                + clickup.selectedFolderIds.count
                + clickup.selectedListIds.count
            Text(total == 0
                 ? "Recherche par défaut : tâches qui te sont assignées."
                 : "\(total) sélectionné(s) — la recherche couvre tout leur contenu.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if total > 0 {
                Button("Tout désélectionner") {
                    clickup.clearSelected()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Préfixes (per-list calendar event prefix)

    private var prefixesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Préfixes des évènements Google Calendar",
                      systemImage: "tag.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if clickup.loadingSpaces {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await clickup.loadAllSpaces() }
                } label: {
                    Label("Recharger", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(!clickup.hasToken || clickup.loadingSpaces)
            }

            Text("Cherche une liste et ajoute son préfixe. Le préfixe sera mis entre crochets devant le titre du timer dans Google Calendar (ex. **« [Pompotes] Fix login bug »**).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ListAutocompleteField()

            configuredPrefixesTable
        }
    }

    @ViewBuilder
    private var configuredPrefixesTable: some View {
        let configured = clickup.flatLists
            .filter { clickup.listPrefixes[$0.id] != nil }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Préfixes configurés")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(configured.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if configured.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tag.slash")
                        .foregroundStyle(.tertiary)
                    Text("Aucun préfixe — utilise la recherche au-dessus pour en ajouter.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.04))
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(configured) { list in
                        PrefixRow(list: list)
                        Divider().opacity(0.18)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.04))
                )
            }
        }
    }

    // MARK: - Horaires (working hours per weekday + EOD alert)

    private var workingHoursSection: some View {
        WorkingHoursSection(hours: hours)
    }

    // MARK: - Affichage (preferred screen for the overlay)

    private var displaySection: some View {
        DisplaySection()
    }
}

// MARK: - Working hours section (extracted so it can own selection state)

private struct WorkingHoursSection: View {
    @ObservedObject var hours: WorkingHoursState

    /// Rows the user has marked for multi-edit. Editing the toolbar
    /// time fields propagates to every day in this set.
    @State private var selection: Set<Weekday> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Text("Configure tes horaires jour par jour. Sélectionne plusieurs lignes pour les modifier en une fois. Quand le timer tourne encore après l'heure de fin du jour courant, une **alerte rouge** s'affiche.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            multiEditToolbar

            VStack(spacing: 0) {
                weekdayHeaderRow
                Divider().opacity(0.3)
                ForEach(Weekday.orderedMondayFirst) { day in
                    DayScheduleRow(
                        day: day,
                        schedule: hours.binding(for: day),
                        selected: selection.contains(day),
                        onToggleSelect: { toggleSelection(day) }
                    )
                    Divider().opacity(0.18)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.04))
            )
            .opacity(hours.enabled ? 1 : 0.55)
            .disabled(!hours.enabled)

            HStack(spacing: 14) {
                Button {
                    selection = Set(
                        Weekday.allCases.filter {
                            hours.schedules[$0]?.enabled == true
                        }
                    )
                } label: {
                    Label("Sélectionner les jours ouvrés",
                          systemImage: "checkmark.circle")
                }
                .controlSize(.small)
                .disabled(!hours.enabled)

                Button {
                    resetToDefault()
                } label: {
                    Label("Reset par défaut",
                          systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
                .disabled(!hours.enabled)

                Spacer()
            }

            todaySummary
        }
    }

    private var header: some View {
        HStack {
            Label("Horaires de travail",
                  systemImage: "clock.badge.checkmark")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Toggle("", isOn: Binding(
                get: { hours.enabled },
                set: { hours.enabled = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    /// Sticky toolbar that appears when one or more days are selected.
    /// Editing the time fields applies the change to every selected
    /// day at once. Kept tight (32pt tall) so the schedule table
    /// doesn't get pushed down dramatically.
    @ViewBuilder
    private var multiEditToolbar: some View {
        if !selection.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("\(selection.count) j.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                Divider().frame(height: 14).opacity(0.3)

                MultiEditTimePair(
                    label: "Matin",
                    start: bulkBinding(\.morningStart),
                    end:   bulkBinding(\.morningEnd)
                )
                MultiEditTimePair(
                    label: "Aprem",
                    start: bulkBinding(\.afternoonStart),
                    end:   bulkBinding(\.afternoonEnd)
                )

                Spacer(minLength: 6)

                Divider().frame(height: 14).opacity(0.3)

                CompactPillButton(
                    icon: "checkmark", tint: Color(red: 0.2, green: 0.7, blue: 0.4)
                ) { setEnabledForSelected(true) }
                    .help("Marquer les jours sélectionnés comme jours ouvrés")

                CompactPillButton(
                    icon: "moon", tint: .secondary
                ) { setEnabledForSelected(false) }
                    .help("Marquer les jours sélectionnés comme jours off")

                Button {
                    selection.removeAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .help("Désélectionner tout")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Color.accentColor.opacity(0.30), lineWidth: 0.7
                    )
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var weekdayHeaderRow: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 22) // selection column
            Spacer().frame(width: 22) // enabled toggle column
            Text("Jour").frame(width: 90, alignment: .leading)
            Spacer().frame(width: 4)
            Text("Matin").frame(width: 130, alignment: .leading)
            Text("Après-midi").frame(width: 130, alignment: .leading)
            Spacer()
        }
        .font(.system(size: 10, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var todaySummary: some View {
        let weekdayInt = Calendar.current.component(.weekday, from: Date())
        if let weekday = Weekday(rawValue: weekdayInt),
           let today = hours.schedules[weekday] {
            HStack(spacing: 6) {
                if hours.enabled && today.enabled {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                    Text("Aujourd'hui (\(weekday.label.lowercased())) → fin de journée à \(today.afternoonEnd.formatted)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("Aujourd'hui (\(weekday.label.lowercased())) → pas de jour ouvré, aucune alerte de fin de journée.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Selection / multi-edit helpers

    private func toggleSelection(_ day: Weekday) {
        withAnimation(.easeOut(duration: 0.14)) {
            if selection.contains(day) {
                selection.remove(day)
            } else {
                selection.insert(day)
            }
        }
    }

    /// A binding that, when read, returns the value common to every
    /// selected day (or the first day's value if they differ); when
    /// written, applies the new value to *every* selected day.
    private func bulkBinding(
        _ keyPath: WritableKeyPath<DaySchedule, TimeOfDay>
    ) -> Binding<TimeOfDay> {
        Binding(
            get: {
                let values = self.selection.compactMap {
                    self.hours.schedules[$0]?[keyPath: keyPath]
                }
                let unique = Set(values)
                return unique.count == 1
                    ? values.first!
                    : (values.first ?? TimeOfDay(hour: 9, minute: 0))
            },
            set: { new in
                for day in self.selection {
                    var s = self.hours.schedules[day] ?? .workdayDefault
                    s[keyPath: keyPath] = new
                    self.hours.schedules[day] = s
                }
            }
        )
    }

    private func setEnabledForSelected(_ on: Bool) {
        for day in selection {
            var s = hours.schedules[day] ?? .workdayDefault
            s.enabled = on
            hours.schedules[day] = s
        }
    }

    private func resetToDefault() {
        hours.schedules[.monday]    = .workdayDefault
        hours.schedules[.tuesday]   = .workdayDefault
        hours.schedules[.wednesday] = .workdayDefault
        hours.schedules[.thursday]  = .workdayDefault
        hours.schedules[.friday]    = .fridayDefault
        hours.schedules[.saturday]  = .weekendDefault
        hours.schedules[.sunday]    = .weekendDefault
        selection.removeAll()
    }
}

/// Compact "Matin HH:MM → HH:MM" pair used inside the multi-edit
/// toolbar. Tighter than the in-row fields so the toolbar stays in a
/// single 34pt-tall band.
private struct MultiEditTimePair: View {
    let label: String
    @Binding var start: TimeOfDay
    @Binding var end: TimeOfDay

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.trailing, 1)
            TimeOfDayField(time: $start)
            Text("→")
                .foregroundStyle(.tertiary)
                .font(.system(size: 10))
            TimeOfDayField(time: $end)
        }
    }
}

/// Small icon-only pill button — used in the multi-edit toolbar so
/// the row stays slim.
private struct CompactPillButton: View {
    let icon: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(hovering ? 0.18 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(tint.opacity(0.32), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { v in
            withAnimation(.easeOut(duration: 0.12)) { hovering = v }
        }
    }
}

// MARK: - Autocomplete to add a list

/// Search input with a popover of matching lists. Picking a match adds
/// it to the prefixes table with an empty prefix, ready to edit.
private struct ListAutocompleteField: View {
    @ObservedObject private var clickup = ClickUpService.shared
    @State private var query: String = ""
    @State private var open: Bool = false
    @FocusState private var focused: Bool

    private var matches: [ClickUpFlatList] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Don't show already-configured lists in the autocomplete; they
        // already appear in the table below.
        let unconfigured = clickup.flatLists.filter {
            (clickup.listPrefixes[$0.id] ?? "").isEmpty
        }
        if q.isEmpty {
            return Array(unconfigured.prefix(8))
        }
        return unconfigured
            .filter {
                $0.name.lowercased().contains(q)
                    || $0.path.lowercased().contains(q)
            }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Chercher une liste à préfixer…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
                .onChange(of: focused) { _, f in
                    if f { open = true }
                }
                .onChange(of: query) { _, _ in
                    if focused { open = true }
                }

            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    focused ? Color.accentColor.opacity(0.45)
                            : Color.primary.opacity(0.10),
                    lineWidth: 0.7
                )
        )
        .popover(isPresented: $open, arrowEdge: .bottom) {
            autocompletePopover
        }
    }

    private var autocompletePopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if clickup.flatLists.isEmpty {
                HStack(spacing: 8) {
                    if clickup.loadingSpaces {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "tray")
                            .foregroundStyle(.tertiary)
                    }
                    Text(clickup.loadingSpaces
                         ? "Chargement des listes ClickUp…"
                         : "Aucune liste connue. Clique « Recharger » à droite.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(width: 380)
            } else if matches.isEmpty {
                Text("Aucune correspondance.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(width: 380)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matches) { list in
                            AutocompleteRow(list: list) {
                                clickup.addPrefix(forListId: list.id)
                                query = ""
                                open = false
                                focused = false
                            }
                            Divider().opacity(0.14)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(width: 380, height: min(CGFloat(matches.count) * 38 + 8, 320))
            }
        }
    }
}

private struct AutocompleteRow: View {
    let list: ClickUpFlatList
    let onPick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.purple.opacity(0.85))
                    .font(.system(size: 11))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(list.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(list.path)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(hovering
                                     ? Color.accentColor
                                     : Color.secondary.opacity(0.6))
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                hovering ? Color.accentColor.opacity(0.10) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { hovering = $0 }
    }
}

// MARK: - Préfixes row

private struct PrefixRow: View {
    let list: ClickUpFlatList
    @ObservedObject private var clickup = ClickUpService.shared
    @State private var draft: String = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var stored: String { clickup.listPrefixes[list.id] ?? "" }
    private var dirty: Bool { draft != stored }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet")
                .foregroundStyle(.purple.opacity(0.85))
                .font(.system(size: 11))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(list.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(list.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            HStack(spacing: 0) {
                Text("[")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                TextField("préfixe", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(width: 120)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, f in
                        if !f { commit() }
                    }
                Text("]")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(focused
                          ? Color.accentColor.opacity(0.10)
                          : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        focused
                            ? Color.accentColor.opacity(0.45)
                            : Color.primary.opacity(0.10),
                        lineWidth: 0.7
                    )
            )

            Button { commit() } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .opacity(dirty ? 1 : 0.001)
            .help("Sauvegarder")
            .cursor(.pointingHand)

            Button {
                clickup.removePrefix(forListId: list.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0))
                    )
            }
            .buttonStyle(.plain)
            .help("Retirer la liste")
            .cursor(.pointingHand)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hovering
                    ? Color.accentColor.opacity(0.05)
                    : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onAppear { draft = stored }
        .onChange(of: stored) { _, new in
            if !focused { draft = new }
        }
    }

    private func commit() {
        clickup.setPrefix(draft, forListId: list.id)
    }
}

// MARK: - Display (preferred screen) section

private struct DisplaySection: View {
    /// Refresh trigger — bumped when displays change (lid open, monitor
    /// connect/disconnect) so the picker reflects the new lineup.
    @State private var refresh = 0
    /// The currently chosen display id, mirrored into UserDefaults.
    /// `0` means "système" (NSScreen.main, follows the OS).
    @State private var selected: Int = Int(OverlayPanel.preferredDisplayID ?? 0)

    private var screens: [NSScreen] { NSScreen.screens }

    private func displayId(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID) ?? 0
    }

    private func size(of screen: NSScreen) -> String {
        let f = screen.frame
        return "\(Int(f.width))×\(Int(f.height))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Écran d'affichage de la pill",
                  systemImage: "macwindow")
                .font(.system(size: 13, weight: .semibold))

            Text("Choisis l'écran sur lequel la pill apparaît sous le notch. Si l'écran préféré est débranché, la pill bascule automatiquement sur l'écran principal.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                screenRow(
                    id: 0,
                    title: "Suivre le système",
                    subtitle: "Toujours l'écran principal du moment",
                    icon: "gearshape",
                    isSystem: true
                )
                Divider().opacity(0.18)
                ForEach(screens, id: \.self) { screen in
                    screenRow(
                        id: Int(displayId(of: screen)),
                        title: screen.localizedName.isEmpty
                            ? "Écran inconnu"
                            : screen.localizedName,
                        subtitle: "\(size(of: screen)) · " +
                                  (screen == NSScreen.main
                                   ? "écran principal actuel"
                                   : "écran connecté"),
                        icon: NSScreen.main == screen
                            ? "rectangle.inset.filled"
                            : "rectangle",
                        isSystem: false
                    )
                    Divider().opacity(0.18)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.04))
            )
            .id(refresh) // force re-render when displays change

            Spacer()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )) { _ in
            refresh += 1
        }
    }

    @ViewBuilder
    private func screenRow(
        id: Int, title: String, subtitle: String,
        icon: String, isSystem: Bool
    ) -> some View {
        let isSelected = selected == id
        Button {
            selected = id
            OverlayPanel.preferredDisplayID = id == 0
                ? nil : CGDirectDisplayID(id)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSystem
                                     ? Color.secondary
                                     : Color.accentColor.opacity(0.85))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(isSelected
                                     ? Color.accentColor
                                     : Color.secondary.opacity(0.5))
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected
                        ? Color.accentColor.opacity(0.08)
                        : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
    }
}

// MARK: - Per-day schedule row

private struct DayScheduleRow: View {
    let day: Weekday
    @Binding var schedule: DaySchedule
    let selected: Bool
    let onToggleSelect: () -> Void

    @State private var hovering = false

    private var isToday: Bool {
        Calendar.current.component(.weekday, from: Date()) == day.rawValue
    }

    var body: some View {
        HStack(spacing: 10) {
            // Multi-edit selection.
            Button(action: onToggleSelect) {
                Image(systemName: selected
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(selected
                                     ? Color.accentColor
                                     : Color.secondary.opacity(0.5))
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .frame(width: 22)
            .cursor(.pointingHand)
            .help(selected
                  ? "Retirer de la sélection"
                  : "Ajouter à la sélection multi-édition")

            // Working-day toggle (disables the day entirely).
            Toggle("", isOn: $schedule.enabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .frame(width: 22)

            HStack(spacing: 4) {
                Text(day.label)
                    .font(.system(size: 12, weight: isToday ? .semibold : .medium))
                    .foregroundStyle(schedule.enabled ? .primary : .secondary)
                if isToday {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("aujourd'hui")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 140, alignment: .leading)

            HStack(spacing: 4) {
                TimeOfDayField(time: $schedule.morningStart)
                Text("→").foregroundStyle(.tertiary).font(.system(size: 11))
                TimeOfDayField(time: $schedule.morningEnd)
            }
            .frame(width: 130, alignment: .leading)
            .opacity(schedule.enabled ? 1 : 0.45)
            .disabled(!schedule.enabled)

            HStack(spacing: 4) {
                TimeOfDayField(time: $schedule.afternoonStart)
                Text("→").foregroundStyle(.tertiary).font(.system(size: 11))
                TimeOfDayField(time: $schedule.afternoonEnd)
            }
            .frame(width: 130, alignment: .leading)
            .opacity(schedule.enabled ? 1 : 0.45)
            .disabled(!schedule.enabled)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            selected
                ? Color.accentColor.opacity(0.10)
                : (isToday
                    ? Color.accentColor.opacity(0.05)
                    : (hovering ? Color.primary.opacity(0.03) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggleSelect() }
        .onHover { hovering = $0 }
    }
}

// MARK: - TimeOfDay field (HH:MM steppers)

private struct TimeOfDayField: View {
    @Binding var time: TimeOfDay
    @State private var hovering = false

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                var c = Calendar.current.dateComponents(
                    [.year, .month, .day], from: Date()
                )
                c.hour = time.hour
                c.minute = time.minute
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { newDate in
                time = TimeOfDay.from(date: newDate)
            }
        )
    }

    var body: some View {
        DatePicker("", selection: dateBinding, displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 58)
    }
}

// MARK: - Alert status card (countdown to next alert)

private struct AlertStatusCard: View {
    @ObservedObject var idleAlert: IdleAlertState
    @ObservedObject var timer: TimerState
    @ObservedObject var hours: WorkingHoursState

    var body: some View {
        // TimelineView ticks every second so the countdown is live.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            HStack(spacing: 10) {
                AlertStatusRow(
                    icon: "exclamationmark.triangle.fill",
                    accent: Color(red: 1.0, green: 0.86, blue: 0.10),
                    label: "Oubli timer",
                    state: idleStateText(now: now),
                    detail: idleDetailText(now: now)
                )
                AlertStatusRow(
                    icon: "moon.stars.fill",
                    accent: Color(red: 1.0, green: 0.30, blue: 0.32),
                    label: "Fin de journée",
                    state: eodStateText(now: now),
                    detail: eodDetailText(now: now)
                )
            }
        }
    }

    // MARK: idle state

    private func idleStateText(now: Date) -> String {
        if timer.isRunning { return "Inactive (timer en cours)" }
        if let s = idleAlert.snoozedUntil, s > now {
            return "En sourdine"
        }
        if idleAlert.isAlertActive { return "Active maintenant" }
        return "Programmée"
    }

    private func idleDetailText(now: Date) -> String? {
        if timer.isRunning { return nil }
        if let s = idleAlert.snoozedUntil, s > now {
            return "Jusqu'à \(timeFmt(s)) · \(remaining(from: now, to: s))"
        }
        if idleAlert.isAlertActive { return "—" }
        // Try to compute time until threshold.
        if let last = idleLastActivity() {
            let target = last.addingTimeInterval(idleAlert.idleThreshold)
            if target > now {
                return "Dans \(remaining(from: now, to: target))"
            }
        }
        return "Bientôt"
    }

    /// Reads the same UserDefaults key IdleAlertState uses.
    private func idleLastActivity() -> Date? {
        UserDefaults.standard.object(forKey: "idle_alert_last_activity") as? Date
    }

    // MARK: end-of-day state

    private func eodStateText(now: Date) -> String {
        if !hours.enabled { return "Désactivée" }
        if hours.endOfDayToday == nil { return "Jour off" }
        if !timer.isRunning { return "En attente du timer" }
        if let s = idleAlert.endOfDaySnoozedUntil, s > now {
            return "En sourdine"
        }
        if idleAlert.isEndOfDayAlertActive { return "Active maintenant" }
        return "Programmée"
    }

    private func eodDetailText(now: Date) -> String? {
        if !hours.enabled { return "Active dans l'onglet Horaires" }
        guard let endOfDay = hours.endOfDayToday else {
            return "Aujourd'hui n'est pas un jour ouvré."
        }
        if !timer.isRunning {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return "Déclenchée si timer toujours actif à \(f.string(from: endOfDay))"
        }
        if let s = idleAlert.endOfDaySnoozedUntil, s > now {
            return "Jusqu'à \(timeFmt(s)) · \(remaining(from: now, to: s))"
        }
        if idleAlert.isEndOfDayAlertActive { return "—" }
        if endOfDay > now {
            return "À \(timeFmt(endOfDay)) · dans \(remaining(from: now, to: endOfDay))"
        }
        return "Bientôt"
    }

    // MARK: - formatting

    private func timeFmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private func remaining(from now: Date, to target: Date) -> String {
        let s = max(0, Int(target.timeIntervalSince(now)))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return "\(h) h \(String(format: "%02d", m)) min"
        }
        if m >= 5 {
            return "\(m) min"
        }
        return "\(m) min \(String(format: "%02d", sec)) s"
    }
}

private struct AlertStatusRow: View {
    let icon: String
    let accent: Color
    let label: String
    let state: String
    let detail: String?

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(label)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("·")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 10))
                    Text(state)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
    }
}

// MARK: - Tree rows

private struct SpaceRow: View {
    let space: ClickUpSpace
    @ObservedObject private var clickup = ClickUpService.shared
    @State private var expanded = false
    @State private var hovering = false

    private var isOn: Bool { clickup.selectedSpaceIds.contains(space.id) }

    private var hasChildren: Bool {
        !space.folders.isEmpty || !space.folderlessLists.isEmpty
    }

    private var childCount: Int {
        space.folders.count + space.folderlessLists.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if expanded && hasChildren {
                ForEach(space.folders) { folder in
                    FolderRow(folder: folder, parentSelected: isOn)
                }
                ForEach(space.folderlessLists) { list in
                    ListRow(list: list, parentSelected: isOn)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                    .opacity(hasChildren ? 1 : 0)
            }
            .buttonStyle(.plain)
            .disabled(!hasChildren)

            Button { clickup.toggleSpace(space.id) } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)

            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 12))

            Text(space.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 0)

            if hasChildren {
                Text("\(childCount)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(hovering
                    ? Color.accentColor.opacity(0.06)
                    : Color.clear)
        .contentShape(Rectangle())
        .cursor(.pointingHand)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
        }
    }
}

private struct ListRow: View {
    let list: ClickUpList
    let parentSelected: Bool
    var indent: CGFloat = 24
    @ObservedObject private var clickup = ClickUpService.shared
    @State private var hovering = false

    private var isOn: Bool {
        parentSelected || clickup.selectedListIds.contains(list.id)
    }

    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: indent)
            Button {
                guard !parentSelected else { return }
                clickup.toggleList(list.id)
            } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .opacity(parentSelected ? 0.45 : 1)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(parentSelected)

            Image(systemName: "list.bullet")
                .foregroundStyle(.purple.opacity(0.8))
                .font(.system(size: 11))

            Text(list.name)
                .font(.system(size: 12))
                .foregroundStyle(parentSelected ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                Task { await clickup.inspectList(list) }
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Lister toutes les tâches de cette liste dans les logs")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hovering ? Color.accentColor.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .cursor(.pointingHand)
        .onHover { hovering = $0 }
    }
}

private struct FolderRow: View {
    let folder: ClickUpFolder
    let parentSelected: Bool
    @ObservedObject private var clickup = ClickUpService.shared
    @State private var expanded = false
    @State private var hovering = false

    private var isOn: Bool {
        parentSelected || clickup.selectedFolderIds.contains(folder.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if expanded {
                ForEach(folder.lists) { list in
                    ListRow(list: list,
                            parentSelected: isOn,
                            indent: 48)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 12)
            Button {
                withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                    .opacity(folder.lists.isEmpty ? 0 : 1)
            }
            .buttonStyle(.plain)
            .disabled(folder.lists.isEmpty)

            Button {
                guard !parentSelected else { return }
                clickup.toggleFolder(folder.id)
            } label: {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                    .opacity(parentSelected ? 0.45 : 1)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(parentSelected)

            Image(systemName: "folder.fill")
                .foregroundStyle(.orange.opacity(0.85))
                .font(.system(size: 11))

            Text(folder.name)
                .font(.system(size: 12))
                .foregroundStyle(parentSelected ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if !folder.lists.isEmpty {
                Text("\(folder.lists.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task { await clickup.inspectFolder(folder) }
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Lister les tâches de toutes ses listes dans les logs")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hovering ? Color.accentColor.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .cursor(.pointingHand)
        .onHover { hovering = $0 }
    }
}
