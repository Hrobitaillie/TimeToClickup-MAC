import Foundation

final class RecentTasksStore {
    private let key = "recent_tasks_v1"
    private let max = 12

    func load() -> [ClickUpTask] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let tasks = try? JSONDecoder().decode([ClickUpTask].self, from: data)
        else { return [] }
        return tasks
    }

    func save(_ tasks: [ClickUpTask]) {
        let trimmed = Array(tasks.prefix(max))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
