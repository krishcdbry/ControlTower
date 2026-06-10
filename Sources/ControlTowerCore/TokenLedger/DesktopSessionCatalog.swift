import Foundation

/// Maps Claude Desktop / Cowork sessions to their CLI transcript ids.
///
/// Claude Desktop (including Cowork) runs Claude Code under the hood and
/// writes standard transcripts into ~/.claude/projects. The Desktop app also
/// keeps per-session metadata at
/// `~/Library/Application Support/Claude/claude-code-sessions/<account>/<workspace>/local_*.json`
/// whose `cliSessionId` field is the transcript's session UUID (the JSONL
/// filename). Collecting those ids lets the ledger attribute usage to
/// Desktop/Cowork vs. plain Claude Code.
public enum DesktopSessionCatalog {
    /// Returns the set of transcript session UUIDs (lowercased) that belong to Claude Desktop / Cowork.
    public static func desktopSessionIDs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Set<String> {
        let root = home
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
        return self.desktopSessionIDs(inRoot: root)
    }

    static func desktopSessionIDs(inRoot root: URL) -> Set<String> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }

        var ids: Set<String> = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "json", fileURL.lastPathComponent.hasPrefix("local_") else { continue }
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            if let id = self.extractCLISessionID(from: data) {
                ids.insert(id.lowercased())
            }
        }
        return ids
    }

    /// Pulls `cliSessionId` out of a Desktop session metadata file without
    /// decoding the whole document (they embed large MCP tool manifests).
    static func extractCLISessionID(from data: Data) -> String? {
        let needle = Data(#""cliSessionId""#.utf8)
        guard let keyRange = data.range(of: needle) else { return nil }

        var index = keyRange.upperBound
        let bytes = data
        // Skip whitespace and the colon.
        while index < bytes.endIndex, bytes[index] == 0x3A || bytes[index] == 0x20 || bytes[index] == 0x09 {
            index = bytes.index(after: index)
        }
        guard index < bytes.endIndex, bytes[index] == 0x22 else { return nil } // opening quote
        index = bytes.index(after: index)

        var valueBytes: [UInt8] = []
        while index < bytes.endIndex, bytes[index] != 0x22, valueBytes.count < 64 {
            valueBytes.append(bytes[index])
            index = bytes.index(after: index)
        }
        guard !valueBytes.isEmpty else { return nil }
        return String(decoding: valueBytes, as: UTF8.self)
    }
}
