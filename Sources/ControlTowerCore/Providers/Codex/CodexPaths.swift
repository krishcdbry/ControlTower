import Foundation

enum CodexPaths {
    static func home(environment: [String: String]) -> URL {
        if let path = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    static func sessionRoots(environment: [String: String]) -> [URL] {
        let home = Self.home(environment: environment)
        return ["sessions", "archived_sessions"].map { home.appendingPathComponent($0, isDirectory: true) }
    }
}
