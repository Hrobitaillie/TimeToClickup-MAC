import Foundation

struct ClickUpTask: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    var status: String?
    var listName: String?
    var folderName: String?
    var spaceName: String?
    var url: String?
}

// MARK: - API DTOs

struct TeamsResponse: Decodable {
    let teams: [Team]
    struct Team: Decodable {
        let id: String
        let name: String
    }
}

struct UserResponse: Decodable {
    let user: User
    struct User: Decodable {
        let id: Int
        let username: String?
    }
}

struct TasksResponse: Decodable {
    let tasks: [RawTask]
    struct RawTask: Decodable {
        let id: String
        let name: String
        let status: Status?
        let list: NamedRef?
        let folder: NamedRef?
        let space: NamedRef?
        let parent: String?
        let url: String?
        struct Status: Decodable { let status: String }
        struct NamedRef: Decodable {
            let id: String?
            let name: String?
        }
    }
}

extension TasksResponse.RawTask {
    var asTask: ClickUpTask {
        ClickUpTask(
            id: id,
            name: name,
            status: status?.status,
            listName: list?.name,
            folderName: folder?.name,
            spaceName: space?.name,
            url: url
        )
    }

    /// Human-readable path for debugging: "Space › Folder › List"
    var path: String {
        [space?.name, folder?.name, list?.name]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != "hidden" }
            .joined(separator: " › ")
    }
}

// MARK: - Spaces / Folders / Lists

struct SpacesResponse: Decodable {
    let spaces: [Raw]
    struct Raw: Decodable {
        let id: String
        let name: String
    }
}

struct FoldersResponse: Decodable {
    let folders: [Raw]
    struct Raw: Decodable {
        let id: String
        let name: String
        let lists: [RawList]
    }
    struct RawList: Decodable {
        let id: String
        let name: String
    }
}

struct ListsResponse: Decodable {
    let lists: [Raw]
    struct Raw: Decodable {
        let id: String
        let name: String
    }
}

struct ClickUpList: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Flattened list reference used by the search filter picker:
/// the list itself plus the "Space › Folder" path so the user can
/// disambiguate same-named lists across the workspace.
struct ClickUpFlatList: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
}

// MARK: - Time entries

struct RunningEntry: Equatable {
    let id: String
    let taskId: String?
    let taskName: String?
    let description: String?
    let startedAt: Date
}

struct CurrentTimeEntryResponse: Decodable {
    let data: Entry?
    struct Entry: Decodable {
        let id: String?
        let task: TaskRef?
        let description: String?
        let start: FlexibleNumber?
        let end: FlexibleNumber?
        struct TaskRef: Decodable {
            let id: String
            let name: String?
        }
    }
}

struct StartTimeEntryResponse: Decodable {
    let data: Entry?
    struct Entry: Decodable {
        let id: String
    }
}

/// ClickUp returns timestamps inconsistently: sometimes JSON numbers,
/// sometimes strings (e.g. `"0"`). We normalize both.
enum FlexibleNumber: Decodable {
    case int(Int64)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int64.self) { self = .int(n); return }
        if let d = try? c.decode(Double.self) { self = .int(Int64(d)); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(
            FlexibleNumber.self,
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "Expected number or string")
        )
    }

    var asInt64: Int64? {
        switch self {
        case .int(let n): return n
        case .string(let s): return Int64(s)
        }
    }

    var asDate: Date? {
        guard let ms = asInt64, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}

struct ClickUpFolder: Identifiable, Hashable {
    let id: String
    let name: String
    var lists: [ClickUpList] = []
    var listIds: [String] { lists.map(\.id) }
}

struct ClickUpSpace: Identifiable, Hashable {
    let id: String
    let name: String
    var folders: [ClickUpFolder] = []
    var folderlessLists: [ClickUpList] = []
}
