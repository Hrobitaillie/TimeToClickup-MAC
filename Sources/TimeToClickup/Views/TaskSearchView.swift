import SwiftUI

struct TaskSearchView: View {
    @EnvironmentObject var clickup: ClickUpService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var results: [ClickUpTask] = []
    @State private var loading = false
    @State private var searchTask: Task<Void, Never>?
    @State private var fieldFocused = false
    @FocusState private var focused: Bool

    @State private var pickingList = false
    @State private var listPickerQuery = ""

    let onPick: (ClickUpTask) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                listFilterRow
                searchField
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
            Divider().opacity(0.4)

            ZStack {
                if pickingList {
                    listPickerSection
                        .transition(.opacity)
                } else {
                    content
                        .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(width: 360, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .onAppear {
            focused = true
            clickup.preloadSearch()
        }
    }

    // MARK: - List filter pill + inline picker

    private var listFilterRow: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    pickingList.toggle()
                    if pickingList { listPickerQuery = "" }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: clickup.searchListFilter == nil
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 11))
                    Text(clickup.searchListFilterDisplayName
                         ?? "Toutes les listes")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: pickingList ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(clickup.searchListFilter == nil
                                 ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        clickup.searchListFilter == nil
                            ? Color.secondary.opacity(0.10)
                            : Color.accentColor.opacity(0.12)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        clickup.searchListFilter == nil
                            ? Color.clear
                            : Color.accentColor.opacity(0.4),
                        lineWidth: 0.8
                    )
                )
            }
            .buttonStyle(.plain)

            if clickup.searchListFilter != nil {
                Button {
                    clickup.setSearchListFilter(nil)
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        scheduleSearch(query)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Retirer le filtre de liste")
            }

            Spacer()
        }
    }

    private var listPickerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filtrer parmi tes listes…", text: $listPickerQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().opacity(0.3)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ListPickerRow(
                        label: "Toutes les listes",
                        path: nil,
                        selected: clickup.searchListFilter == nil
                    ) {
                        clickup.setSearchListFilter(nil)
                        withAnimation(.easeOut(duration: 0.18)) {
                            pickingList = false
                        }
                        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                            scheduleSearch(query)
                        }
                    }
                    Divider().opacity(0.2).padding(.leading, 36)

                    if filteredFlatLists.isEmpty {
                        if clickup.flatLists.isEmpty && clickup.loadingSpaces {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Chargement des listes…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                        } else {
                            Text(clickup.flatLists.isEmpty
                                 ? "Aucune liste disponible."
                                 : "Aucune correspondance.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        ForEach(filteredFlatLists) { item in
                            ListPickerRow(
                                label: item.name,
                                path: item.path,
                                selected: clickup.searchListFilter == item.id
                            ) {
                                clickup.setSearchListFilter(item.id)
                                withAnimation(.easeOut(duration: 0.18)) {
                                    pickingList = false
                                }
                                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                                    scheduleSearch(query)
                                }
                            }
                            Divider().opacity(0.15).padding(.leading, 36)
                        }
                    }
                }
            }
        }
    }

    private var filteredFlatLists: [ClickUpFlatList] {
        let q = listPickerQuery
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if q.isEmpty { return clickup.flatLists }
        return clickup.flatLists.filter {
            $0.name.lowercased().contains(q)
                || $0.path.lowercased().contains(q)
        }
    }

    // MARK: - Search field (rounded, with focus ring)

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(fieldFocused ? Color.accentColor : .secondary)
                .animation(.easeOut(duration: 0.18), value: fieldFocused)

            TextField("Rechercher une tâche…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onChange(of: query) { _, new in scheduleSearch(new) }
                .onChange(of: focused) { _, v in
                    withAnimation(.easeOut(duration: 0.18)) { fieldFocused = v }
                }

            if loading || clickup.loadingTasks {
                ProgressView().controlSize(.small)
                    .transition(.opacity)
            } else if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
        .animation(.easeOut(duration: 0.18), value: query.isEmpty)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !query.isEmpty {
                    sectionHeader("Résultats", count: results.count)
                } else if !clickup.recentTasks.isEmpty {
                    sectionHeader("Récents", count: clickup.recentTasks.count)
                }

                ForEach(displayedResults) { task in
                    TaskRow(task: task) { onPick(task) }
                    Divider().padding(.leading, 14).opacity(0.25)
                }

                if displayedResults.isEmpty && !loading {
                    emptyState
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty, let listName = clickup.searchListFilterDisplayName {
            // The list filter is the most likely reason for an empty
            // search — surface a one-click escape hatch.
            VStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.orange)
                Text("Aucun résultat dans « \(listName) »")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text("Le filtre de liste exclut peut-être la tâche.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    clickup.setSearchListFilter(nil)
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        scheduleSearch(query)
                    }
                } label: {
                    Label("Chercher dans toutes les listes",
                          systemImage: "xmark.circle")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
        } else {
            VStack(spacing: 8) {
                Image(systemName: query.isEmpty
                      ? "clock.arrow.circlepath" : "magnifyingglass")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(query.isEmpty
                     ? "Aucune tâche récente"
                     : "Aucun résultat pour « \(query) »")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let err = clickup.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 10))
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                hint("↑↓", "naviguer")
                hint("↵", "valider")
                hint("esc", "fermer")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.04))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                )
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.trailing, 4)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }

    private var displayedResults: [ClickUpTask] {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? clickup.recentTasks
            : results
    }

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = []
            loading = false
            return
        }
        loading = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            if Task.isCancelled { return }
            let r = await clickup.search(query: trimmed)
            if Task.isCancelled { return }
            await MainActor.run {
                self.results = r
                self.loading = false
            }
        }
    }
}

// MARK: - List picker row

private struct ListPickerRow: View {
    let label: String
    let path: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(
                            size: 12,
                            weight: selected ? .semibold : .medium
                        ))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let path {
                        Text(path)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                hovering
                    ? Color.accentColor.opacity(0.10)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .onHover { hovering = $0 }
    }
}

// MARK: - Task row

struct TaskRow: View {
    let task: ClickUpTask
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Accent edge slides in on hover for a clear "this is the
                // current row" affordance.
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .opacity(hovering ? 1 : 0)
                    .padding(.vertical, 2)

                statusDot

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let path = pathLabel {
                        Text(path)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let status = task.status {
                    Text(status.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hovering
                    ? Color.accentColor.opacity(0.14)
                    : Color.clear
            )
            .scaleEffect(pressed ? 0.985 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    withAnimation(
                        .interactiveSpring(response: 0.25, dampingFraction: 0.7)
                    ) { pressed = false }
                }
        )
    }

    private var pathLabel: String? {
        let parts = [task.spaceName, task.folderName, task.listName]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != "hidden" }
        return parts.isEmpty ? nil : parts.joined(separator: " › ")
    }

    private var statusDot: some View {
        Circle()
            .fill(Color.accentColor.opacity(hovering ? 0.85 : 0.55))
            .frame(width: 6, height: 6)
    }
}
