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

    private let recentStore = RecentTasksStore()
    private var teamLoadTask: Task<Void, Never>?
    private var userLoadTask: Task<Void, Never>?
    private var inflightSearch: Task<[ClickUpTask], Never>?

    private let selectedSpacesKey = "selected_space_ids"
    private let selectedFoldersKey = "selected_folder_ids"
    private let selectedListsKey = "selected_list_ids"

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
        Task { await ensureTeam() }
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

        // Don't put scope filters in the URL — ClickUp's `name` filter
        // misbehaves when combined with `list_ids[]`/`space_ids[]` and
        // drops deeply-nested subtasks. We do the scope check
        // client-side on the response, which works at any depth
        // because subtasks inherit the parent's list.id.
        var components = URLComponents(
            string: "https://api.clickup.com/api/v2/team/\(teamId)/task"
        )!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "include_closed", value: "false"),
            URLQueryItem(name: "subtasks", value: "true"),
            URLQueryItem(name: "page", value: "0")
        ]

        let useFilter = !ignoreWhitelist && hasAnySelection
        let scopeLabel = useFilter
            ? "filtre client : \(selectedSpaceIds.count) espace(s), " +
              "\(selectedFolderIds.count) sous-espace(s), " +
              "\(selectedListIds.count) liste(s) directe(s)"
            : "SANS filtre"
        LogStore.shared.info("Recherche « \(query) » — \(scopeLabel)")
        if let url = components.url?.absoluteString {
            LogStore.shared.info("→ \(url)")
        }

        do {
            let resp = try await fetchURL(
                components.url!, as: TasksResponse.self
            )
            LogStore.shared.info(
                "← \(resp.tasks.count) tâche(s) reçue(s) du serveur"
            )
            for raw in resp.tasks.prefix(5) {
                let path = raw.path.isEmpty ? "?" : raw.path
                LogStore.shared.info("    · \(raw.name)  [\(path)]")
            }

            let filtered = useFilter
                ? resp.tasks.filter { passesWhitelist($0) }
                : resp.tasks
            if useFilter {
                LogStore.shared.info(
                    "↳ \(filtered.count) après filtre whitelist"
                )
            }
            lastError = nil
            return rankByRelevance(filtered, query: query)
        } catch {
            if Self.isCancellation(error) {
                // Don't log — cancellations are normal between keystrokes.
            } else {
                LogStore.shared.error(
                    "Erreur recherche : \(error.localizedDescription)"
                )
            }
            report("search", error)
            return []
        }
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

    /// Server-side `name` filter already guarantees a substring match
    /// on each result. Sort so exact matches and prefix matches
    /// surface above generic substring matches.
    private func rankByRelevance(
        _ tasks: [TasksResponse.RawTask], query: String
    ) -> [ClickUpTask] {
        let q = query.lowercased()
        return tasks
            .map { ($0, Self.score(name: $0.name, query: q)) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0.name.count < b.0.name.count
            }
            .map { $0.0.asTask }
    }

    private static func score(name: String, query: String) -> Int {
        let n = name.lowercased()
        if n == query { return 0 }
        if n.hasPrefix(query) { return 1 }
        if n.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains(where: { $0.lowercased().hasPrefix(query) }) {
            return 2
        }
        return 3
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
