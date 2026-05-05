import Foundation
import Combine

@MainActor
final class ClickUpService: ObservableObject {
    static let shared = ClickUpService()

    @Published var recentTasks: [ClickUpTask] = []
    @Published var teamId: String?
    @Published var userId: Int?
    @Published var lastError: String?
    @Published var loadingTasks = false
    @Published var loadingSpaces = false
    @Published var availableSpaces: [ClickUpSpace] = []
    @Published private(set) var selectedSpaceIds: Set<String> = []
    @Published private(set) var selectedFolderIds: Set<String> = []
    @Published private(set) var selectedListIds: Set<String> = []
    /// One specific list to scope the search to, picked from the
    /// search popover. Persisted across sessions because users
    /// usually stay on the same project all day.
    @Published var searchListFilter: String?

    /// `listId → prefix` map for calendar event titles. The user
    /// configures this in Settings (e.g. "Pompotes" for the Pompotes
    /// list) so calendar events read like "[Pompotes] Fix login bug".
    @Published private(set) var listPrefixes: [String: String] = [:]

    private let recentStore = RecentTasksStore()
    private var teamLoadTask: Task<Void, Never>?
    private var userLoadTask: Task<Void, Never>?
    private var inflightSearch: Task<[ClickUpTask], Never>?

    private let selectedSpacesKey = "selected_space_ids"
    private let selectedFoldersKey = "selected_folder_ids"
    private let selectedListsKey = "selected_list_ids"
    private let searchListFilterKey = "search_list_filter"
    private let listPrefixesKey = "list_prefixes"

    private var apiToken: String? {
        KeychainHelper.shared.get(key: "clickup_api_token")
    }

    var hasToken: Bool {
        guard let t = apiToken else { return false }
        return !t.isEmpty
    }

    private init() {
        recentTasks = recentStore.load()
        selectedSpaceIds = Set(
            UserDefaults.standard.stringArray(forKey: selectedSpacesKey) ?? []
        )
        selectedFolderIds = Set(
            UserDefaults.standard.stringArray(forKey: selectedFoldersKey) ?? []
        )
        selectedListIds = Set(
            UserDefaults.standard.stringArray(forKey: selectedListsKey) ?? []
        )
        searchListFilter = UserDefaults.standard.string(
            forKey: searchListFilterKey
        )
        if let raw = UserDefaults.standard.dictionary(forKey: listPrefixesKey)
            as? [String: String] {
            listPrefixes = raw
        }
    }

    /// Sets (or replaces) the prefix for a list. An empty string is
    /// kept as a placeholder so the list still appears in the
    /// configured table — calendar formatting treats empty as "no
    /// prefix". Use `removePrefix(forListId:)` to drop the entry
    /// entirely.
    func setPrefix(_ prefix: String, forListId id: String) {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        listPrefixes[id] = trimmed
        UserDefaults.standard.set(listPrefixes, forKey: listPrefixesKey)
    }

    /// Adds a list to the configured set with an empty prefix —
    /// triggered by the autocomplete in Settings. Idempotent.
    func addPrefix(forListId id: String) {
        if listPrefixes[id] == nil {
            listPrefixes[id] = ""
            UserDefaults.standard.set(listPrefixes, forKey: listPrefixesKey)
        }
    }

    func removePrefix(forListId id: String) {
        guard listPrefixes[id] != nil else { return }
        listPrefixes.removeValue(forKey: id)
        UserDefaults.standard.set(listPrefixes, forKey: listPrefixesKey)
    }

    func prefix(forListId id: String?) -> String? {
        guard let id, let p = listPrefixes[id], !p.isEmpty else { return nil }
        return p
    }

    func setSearchListFilter(_ id: String?) {
        searchListFilter = id
        if let id, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: searchListFilterKey)
        } else {
            UserDefaults.standard.removeObject(forKey: searchListFilterKey)
        }
    }

    /// Flat list of every list in the loaded workspace tree, sorted
    /// by path then name — the source of truth for the search filter
    /// picker.
    var flatLists: [ClickUpFlatList] {
        var out: [ClickUpFlatList] = []
        for space in availableSpaces {
            for folder in space.folders {
                for list in folder.lists {
                    out.append(ClickUpFlatList(
                        id: list.id, name: list.name,
                        path: "\(space.name) › \(folder.name)"
                    ))
                }
            }
            for list in space.folderlessLists {
                out.append(ClickUpFlatList(
                    id: list.id, name: list.name, path: space.name
                ))
            }
        }
        return out.sorted {
            $0.path == $1.path ? $0.name < $1.name : $0.path < $1.path
        }
    }

    var searchListFilterDisplayName: String? {
        guard let id = searchListFilter else { return nil }
        return flatLists.first(where: { $0.id == id })?.name
    }

    func reset() {
        teamId = nil
        userId = nil
        availableSpaces = []
    }

    // MARK: - Bootstrap

    func ensureTeam() async {
        if teamId != nil { return }
        if !hasToken { return }
        if let task = teamLoadTask { return await task.value }
        let task = Task<Void, Never> {
            do {
                let teams = try await fetch(path: "/team", as: TeamsResponse.self)
                self.teamId = teams.teams.first?.id
                if let team = teams.teams.first {
                    LogStore.shared.info(
                        "Team chargé : « \(team.name) » (id \(team.id)) — \(teams.teams.count) workspace(s) au total"
                    )
                }
            } catch {
                self.report("team load", error)
            }
        }
        teamLoadTask = task
        await task.value
        teamLoadTask = nil
    }

    func ensureUser() async {
        if userId != nil { return }
        if !hasToken { return }
        if let task = userLoadTask { return await task.value }
        let task = Task<Void, Never> {
            do {
                let resp = try await fetch(path: "/user", as: UserResponse.self)
                self.userId = resp.user.id
                LogStore.shared.info("User chargé : id \(resp.user.id)")
            } catch {
                self.report("user load", error)
            }
        }
        userLoadTask = task
        await task.value
        userLoadTask = nil
    }

    func preloadSearch() {
        Task {
            await ensureTeam()
            if availableSpaces.isEmpty && !loadingSpaces && hasToken {
                await loadAllSpaces()
            }
        }
    }

    // MARK: - Whitelist (Spaces + Folders)

    func toggleSpace(_ id: String) {
        let space = availableSpaces.first { $0.id == id }
        let name = space?.name ?? id
        let folderCount = space?.folders.count ?? 0
        if selectedSpaceIds.contains(id) {
            selectedSpaceIds.remove(id)
            LogStore.shared.info("✗ Espace « \(name) » désélectionné")
        } else {
            selectedSpaceIds.insert(id)
            LogStore.shared.info(
                "✓ Espace « \(name) » sélectionné (\(folderCount) sous-espaces inclus)"
            )
        }
        UserDefaults.standard.set(Array(selectedSpaceIds), forKey: selectedSpacesKey)
    }

    func toggleFolder(_ id: String) {
        let folder = availableSpaces
            .flatMap(\.folders).first { $0.id == id }
        let name = folder?.name ?? id
        let lists = folder?.lists ?? []
        if selectedFolderIds.contains(id) {
            selectedFolderIds.remove(id)
            LogStore.shared.info("✗ Sous-espace « \(name) » désélectionné")
        } else {
            selectedFolderIds.insert(id)
            if lists.isEmpty {
                LogStore.shared.warn(
                    "✓ Sous-espace « \(name) » sélectionné MAIS aucune liste connue. " +
                    "Clique « Recharger »."
                )
            } else {
                LogStore.shared.info(
                    "✓ Sous-espace « \(name) » sélectionné → \(lists.count) liste(s) :"
                )
                for list in lists {
                    LogStore.shared.info("    · \(list.name) (id \(list.id))")
                }
            }
        }
        UserDefaults.standard.set(Array(selectedFolderIds), forKey: selectedFoldersKey)
    }

    func toggleList(_ id: String) {
        let list = availableSpaces
            .flatMap(\.folderlessLists).first { $0.id == id }
        let name = list?.name ?? id
        if selectedListIds.contains(id) {
            selectedListIds.remove(id)
            LogStore.shared.info("✗ Liste « \(name) » désélectionnée")
        } else {
            selectedListIds.insert(id)
            LogStore.shared.info("✓ Liste « \(name) » sélectionnée (id \(id))")
        }
        UserDefaults.standard.set(Array(selectedListIds), forKey: selectedListsKey)
    }

    func clearSelected() {
        selectedSpaceIds = []
        selectedFolderIds = []
        selectedListIds = []
        UserDefaults.standard.set([String](), forKey: selectedSpacesKey)
        UserDefaults.standard.set([String](), forKey: selectedFoldersKey)
        UserDefaults.standard.set([String](), forKey: selectedListsKey)
        LogStore.shared.info("Tous les filtres désélectionnés")
    }

    /// Fetch the workspace tree (spaces + their folders) for the
    /// settings UI. We don't go down to lists — the whitelist works at
    /// the space / folder level only.
    func loadAllSpaces() async {
        await ensureTeam()
        guard let teamId else { return }
        loadingSpaces = true
        defer { loadingSpaces = false }
        LogStore.shared.info("Chargement des espaces…")
        do {
            let spacesResp = try await fetch(
                path: "/team/\(teamId)/space?archived=false",
                as: SpacesResponse.self
            )
            LogStore.shared.info("\(spacesResp.spaces.count) espace(s) trouvés")
            var spaces: [ClickUpSpace] = []
            for s in spacesResp.spaces {
                async let folders = fetch(
                    path: "/space/\(s.id)/folder?archived=false",
                    as: FoldersResponse.self
                )
                async let folderless = fetch(
                    path: "/space/\(s.id)/list?archived=false",
                    as: ListsResponse.self
                )
                let foldersResp = (try? await folders)?.folders ?? []
                let folderlessResp = (try? await folderless)?.lists ?? []

                let parsedFolders = foldersResp.map { f in
                    ClickUpFolder(
                        id: f.id,
                        name: f.name,
                        lists: f.lists.map {
                            ClickUpList(id: $0.id, name: $0.name)
                        }
                    )
                }
                let parsedLists = folderlessResp.map {
                    ClickUpList(id: $0.id, name: $0.name)
                }
                let totalLists = parsedFolders.reduce(0) { $0 + $1.listIds.count }
                LogStore.shared.info(
                    "  • « \(s.name) » : \(parsedFolders.count) sous-espace(s), " +
                    "\(parsedLists.count) liste(s) hors-folder, " +
                    "\(totalLists + parsedLists.count) liste(s) au total"
                )
                spaces.append(ClickUpSpace(
                    id: s.id, name: s.name,
                    folders: parsedFolders,
                    folderlessLists: parsedLists
                ))
            }
            availableSpaces = spaces.sorted { $0.name < $1.name }
            lastError = nil
        } catch {
            report("spaces", error)
        }
    }

    // MARK: - Search

    /// Server-side search via the `name` query parameter on
    /// `GET /team/{team_id}/task`. ClickUp filters task names that
    /// contain the query (substring, case-insensitive). We pass
    /// `subtasks=true` so nested tasks like "moment-effort" show up,
    /// and apply the optional space/folder whitelist.
    func search(query: String, ignoreWhitelist: Bool = false) async
    -> [ClickUpTask] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return recentTasks }

        inflightSearch?.cancel()
        let task = Task<[ClickUpTask], Never> { [weak self] in
            guard let self else { return [] }
            await self.ensureTeam()
            guard let teamId = self.teamId else { return [] }
            return await self.fetchSearchResults(
                teamId: teamId, query: trimmed,
                ignoreWhitelist: ignoreWhitelist
            )
        }
        inflightSearch = task
        return await task.value
    }

    private func fetchSearchResults(
        teamId: String, query: String, ignoreWhitelist: Bool
    ) async -> [ClickUpTask] {
        loadingTasks = true
        defer { loadingTasks = false }

        let useFilter = !ignoreWhitelist && hasAnySelection
        let scopeLabel = useFilter
            ? "filtre client : \(selectedSpaceIds.count) espace(s), " +
              "\(selectedFolderIds.count) sous-espace(s), " +
              "\(selectedListIds.count) liste(s) directe(s)"
            : "SANS filtre"
        LogStore.shared.info("Recherche « \(query) » — \(scopeLabel)")

        // When a single list is pinned, query that list directly. The
        // team `name=` filter is unreliable (returns ~300 tasks of
        // wildly varying relevance, and silently drops some matches
        // beyond page 2). Going through `GET /list/{id}/task` lets us
        // see every task in the scope and match locally.
        if let listId = searchListFilter, !listId.isEmpty, !ignoreWhitelist {
            return await fetchSearchResultsInList(
                listId: listId, query: query
            )
        }

        var collected: [String: TasksResponse.RawTask] = [:]
        do {
            // Primary: full query, paginated up to 3 pages.
            let primary = try await fetchTaskPages(
                teamId: teamId, name: query, maxPages: 3, logURL: true
            )
            for t in primary { collected[t.id] = t }
            LogStore.shared.info("← \(primary.count) tâche(s) via « \(query) »")

            // Fallback: when the query has multiple words / punctuation,
            // ClickUp's substring `name=` filter sometimes drops exact
            // matches (e.g. searching "AV - Solis" misses the task
            // literally named that). Re-search using the longest word
            // alone — that's almost always the most distinctive token —
            // and merge results.
            if let fallback = Self.fallbackQuery(for: query) {
                let extra = try await fetchTaskPages(
                    teamId: teamId, name: fallback, maxPages: 1, logURL: false
                )
                let added = extra.filter { collected[$0.id] == nil }.count
                for t in extra where collected[t.id] == nil {
                    collected[t.id] = t
                }
                LogStore.shared.info(
                    "↺ fallback « \(fallback) » : \(extra.count) tâche(s) (+\(added) nouvelles)"
                )
            }
        } catch {
            if !Self.isCancellation(error) {
                LogStore.shared.error(
                    "Erreur recherche : \(error.localizedDescription)"
                )
                report("search", error)
            }
            return []
        }
        let all = Array(collected.values)

        var filtered = useFilter
            ? all.filter { passesWhitelist($0) }
            : all
        if useFilter {
            LogStore.shared.info(
                "↳ \(filtered.count) après filtre whitelist"
            )
        }

        if let listId = searchListFilter, !listId.isEmpty {
            filtered = filtered.filter { $0.list?.id == listId }
            let listName = searchListFilterDisplayName ?? listId
            LogStore.shared.info(
                "⤷ \(filtered.count) après filtre liste « \(listName) »"
            )
        }

        let ranked = rankByRelevance(filtered, query: query)
        for (i, t) in ranked.prefix(5).enumerated() {
            LogStore.shared.info("    \(i + 1). \(t.name)")
        }
        lastError = nil
        return ranked
    }

    /// List-scoped search. Pulls every task in the list (paginated),
    /// then filters / ranks client-side. Reliable even for tasks that
    /// ClickUp's team-wide `name=` filter inexplicably drops.
    private func fetchSearchResultsInList(
        listId: String, query: String
    ) async -> [ClickUpTask] {
        let listName = searchListFilterDisplayName ?? listId
        var all: [TasksResponse.RawTask] = []
        do {
            for page in 0..<5 {
                var components = URLComponents(
                    string: "https://api.clickup.com/api/v2/list/\(listId)/task"
                )!
                components.queryItems = [
                    URLQueryItem(name: "subtasks", value: "true"),
                    URLQueryItem(name: "include_closed", value: "true"),
                    URLQueryItem(name: "page", value: String(page))
                ]
                if page == 0, let url = components.url?.absoluteString {
                    LogStore.shared.info("→ \(url)")
                }
                let resp = try await fetchURL(
                    components.url!, as: TasksResponse.self
                )
                if resp.tasks.isEmpty { break }
                all.append(contentsOf: resp.tasks)
                if resp.tasks.count < 100 { break }
            }
        } catch {
            if !Self.isCancellation(error) {
                LogStore.shared.error(
                    "Erreur recherche liste : \(error.localizedDescription)"
                )
                report("search list", error)
            }
            return []
        }

        LogStore.shared.info(
            "← \(all.count) tâche(s) dans « \(listName) »"
        )

        // Client-side name filter (case + accent insensitive, multi-word).
        let q = Self.normalize(query)
        let qWords = Self.words(in: q)
        let matched = all.filter { task in
            let n = Self.normalize(task.name)
            if n.contains(q) { return true }
            if qWords.isEmpty { return false }
            // All query words must appear (anywhere) in the name
            return qWords.allSatisfy { n.contains($0) }
        }
        LogStore.shared.info("⤷ \(matched.count) match(s) sur le nom")

        let ranked = rankByRelevance(matched, query: query)
        for (i, t) in ranked.prefix(5).enumerated() {
            LogStore.shared.info("    \(i + 1). \(t.name)")
        }
        lastError = nil
        return ranked
    }

    /// Fetches paginated `name=<query>` results from the team task
    /// endpoint. Stops early on the last page.
    private func fetchTaskPages(
        teamId: String, name: String, maxPages: Int, logURL: Bool
    ) async throws -> [TasksResponse.RawTask] {
        var all: [TasksResponse.RawTask] = []
        for page in 0..<maxPages {
            var components = URLComponents(
                string: "https://api.clickup.com/api/v2/team/\(teamId)/task"
            )!
            components.queryItems = [
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "include_closed", value: "true"),
                URLQueryItem(name: "subtasks", value: "true"),
                URLQueryItem(name: "page", value: String(page))
            ]
            if logURL, page == 0, let url = components.url?.absoluteString {
                LogStore.shared.info("→ \(url)")
            }
            let resp = try await fetchURL(
                components.url!, as: TasksResponse.self
            )
            if resp.tasks.isEmpty { break }
            all.append(contentsOf: resp.tasks)
            if resp.tasks.count < 100 { break }
        }
        return all
    }

    /// Fetches a specific task by id (parsed from a URL or raw id)
    /// via `GET /task/{id}` and dumps its exact name + ids to the logs
    /// — useful to verify what ClickUp considers the canonical title.
    func inspectTask(urlOrId: String) async {
        let trimmed = urlOrId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Extract id from "/t/<id>" or "/t/<id>/..." patterns; otherwise
        // treat the input as a bare id.
        let id: String = {
            if let range = trimmed.range(of: #"/t/([a-z0-9]+)"#,
                                         options: .regularExpression) {
                let captured = String(trimmed[range])
                    .replacingOccurrences(of: "/t/", with: "")
                return captured
            }
            return trimmed
        }()

        LogStore.shared.info("══ INSPECT TASK \(id) ══")
        do {
            let url = URL(string: "https://api.clickup.com/api/v2/task/\(id)")!
            let raw = try await fetchURL(url, as: TasksResponse.RawTask.self)
            LogStore.shared.info("name=\"\(raw.name)\"")
            LogStore.shared.info("    id=\(raw.id)")
            if let l = raw.list {
                LogStore.shared.info("    list=\(l.name ?? "?") (\(l.id ?? "?"))")
            }
            if let f = raw.folder {
                LogStore.shared.info("    folder=\(f.name ?? "?") (\(f.id ?? "?"))")
            }
            if let s = raw.space {
                LogStore.shared.info("    space=\(s.name ?? "?") (\(s.id ?? "?"))")
            }
            if let st = raw.status {
                LogStore.shared.info("    status=\(st.status)")
            }
            if let url = raw.url {
                LogStore.shared.info("    url=\(url)")
            }
            // Hex bytes of the name to expose hidden chars (em-dash,
            // non-breaking space, zero-width, etc.)
            let bytes = raw.name.unicodeScalars
                .map { String(format: "U+%04X", $0.value) }
                .joined(separator: " ")
            LogStore.shared.info("    chars=\(bytes)")
            LogStore.shared.info("══ FIN INSPECT ══")
        } catch {
            LogStore.shared.error("inspect: \(error.localizedDescription)")
        }
    }

    /// Dumps the raw server response for `name=<query>` (no scope, no
    /// whitelist, no list filter, no ranking) to the logs sidebar.
    /// Useful for figuring out whether a missing task is filtered
    /// client-side or simply never returned by ClickUp.
    func dumpRawSearch(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await ensureTeam()
        guard let teamId else {
            LogStore.shared.error("dump: team_id manquant")
            return
        }

        LogStore.shared.info("══ DUMP RAW pour « \(trimmed) » ══")
        LogStore.shared.info("Team : \(teamId)")

        do {
            let primary = try await fetchTaskPages(
                teamId: teamId, name: trimmed, maxPages: 3, logURL: true
            )
            LogStore.shared.info("Primaire « \(trimmed) » : \(primary.count) tâches")
            for t in primary.prefix(50) {
                let path = t.path.isEmpty ? "?" : t.path
                LogStore.shared.info("    \(t.id)  \(t.name)  [\(path)]")
            }
            if primary.count > 50 {
                LogStore.shared.info("    + \(primary.count - 50) tâches non affichées")
            }

            if let fallback = Self.fallbackQuery(for: trimmed) {
                let extra = try await fetchTaskPages(
                    teamId: teamId, name: fallback, maxPages: 1, logURL: true
                )
                LogStore.shared.info("Fallback « \(fallback) » : \(extra.count) tâches")
                let primaryIds = Set(primary.map(\.id))
                let onlyInFallback = extra.filter { !primaryIds.contains($0.id) }
                LogStore.shared.info("    dont \(onlyInFallback.count) absentes de la primaire :")
                for t in onlyInFallback.prefix(50) {
                    let path = t.path.isEmpty ? "?" : t.path
                    LogStore.shared.info("    \(t.id)  \(t.name)  [\(path)]")
                }
            }
            LogStore.shared.info("══ FIN DUMP ══")
        } catch {
            LogStore.shared.error("dump: \(error.localizedDescription)")
        }
    }

    /// Picks a single-word fallback query for multi-word inputs. We
    /// pick the longest alphanumeric token (≥ 4 chars) — heuristically
    /// the most distinctive part of the original query.
    private static func fallbackQuery(for query: String) -> String? {
        let words = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 }
        guard let longest = words.max(by: { $0.count < $1.count }),
              longest.lowercased() != query.lowercased() else {
            return nil
        }
        return longest
    }

    private var hasAnySelection: Bool {
        !selectedSpaceIds.isEmpty
            || !selectedFolderIds.isEmpty
            || !selectedListIds.isEmpty
    }

    private func passesWhitelist(_ task: TasksResponse.RawTask) -> Bool {
        if let spaceId = task.space?.id,
           selectedSpaceIds.contains(spaceId) { return true }
        if let folderId = task.folder?.id,
           selectedFolderIds.contains(folderId) { return true }
        if let listId = task.list?.id {
            if selectedListIds.contains(listId) { return true }
            // Lists inside a selected folder also match.
            if folderListIds(selectedFolderIds).contains(listId) { return true }
        }
        return false
    }

    /// All list IDs covered by the given folder selection.
    private func folderListIds(_ folderIds: Set<String>) -> Set<String> {
        guard !folderIds.isEmpty else { return [] }
        var listIds: Set<String> = []
        for space in availableSpaces {
            for folder in space.folders where folderIds.contains(folder.id) {
                listIds.formUnion(folder.listIds)
            }
        }
        return listIds
    }

    /// Sort the server results by relevance to the query. The server
    /// uses `updated` order by default, so an exact match can easily
    /// be drowned by 99 recently-updated unrelated tasks. We re-rank
    /// here, with diacritic-insensitive matching and support for
    /// multi-word queries (e.g. "moment effort" matches "moment-effort").
    private func rankByRelevance(
        _ tasks: [TasksResponse.RawTask], query: String
    ) -> [ClickUpTask] {
        let q = Self.normalize(query)
        let qWords = Self.words(in: q)
        return tasks
            .map { ($0, Self.score(name: $0.name, query: q, queryWords: qWords)) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0.name.count < b.0.name.count
            }
            .map { $0.0.asTask }
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: nil)
    }

    private static func words(in s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Score buckets (lower = more relevant):
    /// - 0  exact match (case + accent insensitive)
    /// - 1  name starts with the full query
    /// - 2  every query word is a prefix of some name word
    /// - 3  every query word appears anywhere in the name
    /// - 4  full query is a substring of the name
    /// - 5  fallback (server matched it but our heuristics didn't)
    private static func score(
        name: String, query: String, queryWords: [String]
    ) -> Int {
        let n = normalize(name)
        if n == query { return 0 }
        if n.hasPrefix(query) { return 1 }

        let nWords = words(in: n)
        if !queryWords.isEmpty,
           queryWords.allSatisfy({ qw in
               nWords.contains(where: { $0.hasPrefix(qw) })
           }) {
            return 2
        }
        if !queryWords.isEmpty,
           queryWords.allSatisfy({ n.contains($0) }) {
            return 3
        }
        if n.contains(query) { return 4 }
        return 5
    }

    // MARK: - Inspector (debug)

    /// Dumps every task of a given list into the logs, including
    /// subtasks. Pulls a couple of pages so deeply-nested tasks don't
    /// disappear behind pagination.
    func inspectList(_ list: ClickUpList) async {
        LogStore.shared.info("📋 Inspection de la liste « \(list.name) »…")
        var all: [TasksResponse.RawTask] = []
        do {
            for page in 0..<3 {
                var components = URLComponents(
                    string: "https://api.clickup.com/api/v2/list/\(list.id)/task"
                )!
                components.queryItems = [
                    URLQueryItem(name: "subtasks", value: "true"),
                    URLQueryItem(name: "include_closed", value: "true"),
                    URLQueryItem(name: "page", value: String(page))
                ]
                let resp = try await fetchURL(
                    components.url!, as: TasksResponse.self
                )
                if resp.tasks.isEmpty { break }
                all.append(contentsOf: resp.tasks)
                if resp.tasks.count < 100 { break }
            }
            LogStore.shared.info(
                "  → \(all.count) tâche(s) dans « \(list.name) » :"
            )
            // Group by parent so subtasks render under their parent.
            let parents = all.filter { $0.parent == nil }
            let children = Dictionary(grouping: all.filter { $0.parent != nil },
                                      by: { $0.parent! })
            for p in parents.prefix(40) {
                LogStore.shared.info("    · \(p.name)")
                for child in children[p.id] ?? [] {
                    LogStore.shared.info("        ↳ \(child.name)")
                }
            }
            // Surface orphaned subtasks (parent not in this list — typical
            // for nested subtasks of subtasks).
            let knownIds = Set(all.map(\.id))
            let orphans = all.filter {
                if let p = $0.parent { return !knownIds.contains(p) }
                return false
            }
            if !orphans.isEmpty {
                LogStore.shared.info(
                    "    (orphelins — parent hors liste : \(orphans.count))"
                )
                for o in orphans.prefix(30) {
                    LogStore.shared.info("        ↳ \(o.name)  parent=\(o.parent ?? "?")")
                }
            }
            if all.count > 40 + (orphans.count) {
                LogStore.shared.info("    + \(all.count - 40) autres non affichés")
            }
        } catch {
            if !Self.isCancellation(error) {
                LogStore.shared.error(
                    "Inspection liste : \(error.localizedDescription)"
                )
            }
        }
    }

    /// Inspect every list inside a folder.
    func inspectFolder(_ folder: ClickUpFolder) async {
        LogStore.shared.info(
            "📁 Inspection du sous-espace « \(folder.name) » → \(folder.lists.count) liste(s)"
        )
        for list in folder.lists {
            await inspectList(list)
        }
    }

    // MARK: - Time entries

    /// Polls ClickUp for the currently running time entry (if any).
    /// Returns nil when nothing is running on the server.
    func currentRunningEntry() async -> RunningEntry? {
        await ensureTeam()
        guard let teamId else { return nil }
        do {
            let resp = try await fetch(
                path: "/team/\(teamId)/time_entries/current",
                as: CurrentTimeEntryResponse.self
            )
            guard let data = resp.data,
                  let id = data.id,
                  let started = data.start?.asDate else {
                return nil
            }
            // ClickUp returns end="0" while still running.
            if let endMs = data.end?.asInt64, endMs > 0 {
                return nil
            }
            return RunningEntry(
                id: id,
                taskId: data.task?.id,
                taskName: data.task?.name,
                description: data.description,
                startedAt: started
            )
        } catch {
            // Stay quiet on poll errors — they'd flood the log otherwise.
            return nil
        }
    }

    /// Starts a time entry on ClickUp. `taskId` is optional — passing
    /// nil starts a taskless ("no task") entry which can later get a
    /// task attached via `updateTimeEntryTask`.
    /// Returns the new entry id when the API succeeds.
    @discardableResult
    func startTimeEntry(taskId: String?) async -> String? {
        await ensureTeam()
        guard let team = self.teamId else {
            LogStore.shared.warn("⚠ start: team_id manquant — appel ignoré")
            return nil
        }
        var body: [String: Any] = [:]
        if let taskId { body["tid"] = taskId }
        LogStore.shared.info(
            taskId == nil
                ? "▶ POST /time_entries/start (sans tâche)"
                : "▶ POST /time_entries/start tid=\(taskId!)"
        )
        do {
            let data = try await post(
                path: "/team/\(team)/time_entries/start",
                body: body
            )
            let id = (try? JSONDecoder().decode(
                StartTimeEntryResponse.self, from: data
            ))?.data?.id
            LogStore.shared.info(
                "✓ Time entry démarrée sur ClickUp (id \(id ?? "?"))"
            )
            return id
        } catch {
            LogStore.shared.error(
                "✗ start_time_entry: \(error.localizedDescription)"
            )
            report("start entry", error)
            return nil
        }
    }

    /// Attaches a task to an existing (running or stopped) time entry.
    func updateTimeEntryTask(entryId: String, taskId: String) async {
        await ensureTeam()
        guard let team = self.teamId else {
            LogStore.shared.warn("⚠ attach task: team_id manquant — ignoré")
            return
        }
        LogStore.shared.info(
            "✎ PUT tid=\(taskId) sur l'entry \(entryId)"
        )
        do {
            _ = try await put(
                path: "/team/\(team)/time_entries/\(entryId)",
                body: ["tid": taskId]
            )
            LogStore.shared.info("✓ Tâche associée à la time entry")
        } catch {
            LogStore.shared.error(
                "✗ attach task: \(error.localizedDescription)"
            )
            report("attach task", error)
        }
    }

    /// Backdates the start of an existing time entry. ClickUp stores
    /// `start` in milliseconds since epoch; updating it on a running
    /// entry is what we use to launch a timer "il y a X minutes".
    func updateTimeEntryStart(entryId: String, start: Date) async {
        await ensureTeam()
        guard let team = self.teamId else {
            LogStore.shared.warn("⚠ start backdate: team_id manquant — ignoré")
            return
        }
        let ms = Int64(start.timeIntervalSince1970 * 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        LogStore.shared.info(
            "✎ PUT start=\(formatter.string(from: start)) (\(ms)) sur l'entry \(entryId)"
        )
        do {
            _ = try await put(
                path: "/team/\(team)/time_entries/\(entryId)",
                body: ["start": ms]
            )
            LogStore.shared.info("✓ Start backdaté")
        } catch {
            LogStore.shared.error(
                "✗ start backdate: \(error.localizedDescription)"
            )
            report("backdate start", error)
        }
    }

    /// Updates description on an existing running (or completed) entry.
    func updateTimeEntryDescription(entryId: String, description: String) async {
        await ensureTeam()
        guard let team = self.teamId else {
            LogStore.shared.warn("⚠ description: team_id manquant — appel ignoré")
            return
        }
        LogStore.shared.info(
            "✎ PUT description sur l'entry \(entryId) : « \(description) »"
        )
        do {
            _ = try await put(
                path: "/team/\(team)/time_entries/\(entryId)",
                body: ["description": description]
            )
            LogStore.shared.info("✓ Description sauvegardée")
        } catch {
            LogStore.shared.error(
                "✗ description: \(error.localizedDescription)"
            )
            report("update entry", error)
        }
    }

    func stopTimeEntry() async {
        await ensureTeam()
        guard let team = self.teamId else {
            LogStore.shared.warn("⚠ stop: team_id manquant — appel ignoré")
            return
        }
        LogStore.shared.info("■ POST /time_entries/stop")
        do {
            _ = try await post(path: "/team/\(team)/time_entries/stop", body: [:])
            LogStore.shared.info("✓ Time entry arrêtée sur ClickUp")
        } catch {
            LogStore.shared.error(
                "✗ stop_time_entry: \(error.localizedDescription)"
            )
            report("stop entry", error)
        }
    }

    // MARK: - Recents

    func markRecent(_ task: ClickUpTask) {
        recentTasks.removeAll { $0.id == task.id }
        recentTasks.insert(task, at: 0)
        recentStore.save(recentTasks)
    }

    // MARK: - HTTP

    private func fetch<T: Decodable>(path: String, as type: T.Type) async throws -> T {
        let url = URL(string: "https://api.clickup.com/api/v2\(path)")!
        return try await fetchURL(url, as: T.self)
    }

    private func fetchURL<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        guard let token = apiToken else { throw APIError.missingToken }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func put(path: String, body: [String: Any]) async throws -> Data {
        guard let token = apiToken else { throw APIError.missingToken }
        let url = URL(string: "https://api.clickup.com/api/v2\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.validate(response: response, data: data)
        return data
    }

    @discardableResult
    private func post(path: String, body: [String: Any]) async throws -> Data {
        guard let token = apiToken else { throw APIError.missingToken }
        let url = URL(string: "https://api.clickup.com/api/v2\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.validate(response: response, data: data)
        return data
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, body)
        }
    }

    /// Surface an error to the UI, but swallow cancellations — those
    /// happen on every keystroke (we cancel the in-flight request when
    /// a new search starts) and would otherwise flash "search cancelled".
    private func report(_ prefix: String, _ error: Error) {
        if Self.isCancellation(error) { return }
        lastError = "\(prefix): \(error.localizedDescription)"
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }

    enum APIError: LocalizedError {
        case missingToken
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingToken: return "Missing ClickUp API token"
            case let .http(code, body): return "HTTP \(code): \(body.prefix(200))"
            }
        }
    }
}
