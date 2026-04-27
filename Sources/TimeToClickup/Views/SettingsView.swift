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
        win.setContentSize(NSSize(width: 880, height: 620))
        win.center()
        win.isReleasedWhenClosed = false
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var clickup = ClickUpService.shared

    @State private var token: String =
        KeychainHelper.shared.get(key: "clickup_api_token") ?? ""
    @State private var tokenSaved = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                tokenSection
                Divider()
                spacesSection
                Divider()
                searchTestSection
            }
            .padding(20)
            .frame(width: 540)

            Divider()

            LogSidebarView()
                .frame(maxHeight: .infinity)
        }
        .frame(width: 880, height: 720)
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
