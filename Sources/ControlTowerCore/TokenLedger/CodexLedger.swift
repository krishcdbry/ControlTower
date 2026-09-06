import Foundation
import Logging

/// One local day of Codex usage.
public struct CodexLedgerDay: Sendable, Equatable {
    public let date: String // yyyy-MM-dd, local timezone
    public let inputTokens: Int // non-cached input
    public let cachedInputTokens: Int
    public let outputTokens: Int // includes reasoning
    public let reasoningTokens: Int // informational subset of output
    public let costUSD: Double?

    /// Billable token volume (input + cached + output; reasoning is already inside output).
    public var totalTokens: Int { self.inputTokens + self.cachedInputTokens + self.outputTokens }
}

/// Snapshot of Codex usage aggregates.
public struct CodexLedgerSnapshot: Sendable {
    public let generatedAt: Date
    /// Last 30 local days, ascending by date.
    public let days: [CodexLedgerDay]
    public let stats: LedgerScanStats
    public let analytics: LedgerSnapshot
    public let last5Hours: TokenTotals
    public let fallbackModels: Set<String>
    public let fallbackTokens: Int
    public let fallbackCostUSD: Double

    public init(
        generatedAt: Date = Date(), days: [CodexLedgerDay] = [], stats: LedgerScanStats = LedgerScanStats(),
        analytics: LedgerSnapshot = LedgerSnapshot(), last5Hours: TokenTotals = .zero,
        fallbackModels: Set<String> = [], fallbackTokens: Int = 0, fallbackCostUSD: Double = 0
    ) {
        self.generatedAt = generatedAt
        self.days = days
        self.stats = stats
        self.analytics = analytics
        self.last5Hours = last5Hours
        self.fallbackModels = fallbackModels
        self.fallbackTokens = fallbackTokens
        self.fallbackCostUSD = fallbackCostUSD
    }
}

/// Incremental token tracker for Codex Desktop and CLI, mirroring `TokenLedger`:
/// per-file byte cursors, global dedup, minute aggregates in SQLite,
/// priced at query time. Steady-state scans are a stat pass over the roots.
public actor CodexLedger {
    public static let shared = CodexLedger()

    private let logger = Logger(label: "com.controltower.codexledger")
    private let storeURL: URL
    private let environment: [String: String]
    private var store: LedgerStore?

    private var cachedSnapshot: CodexLedgerSnapshot?
    private var lastScanAt: Date?
    private let minScanInterval: TimeInterval = 5
    private let historyCutoffDays = 190
    private let activityDays = 180

    public init(storeURL: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
        self.environment = environment
    }

    static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ControlTower", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("codex-ledger.sqlite")
    }

    // MARK: - Public API

    public func snapshot(forceScan: Bool = false) async -> CodexLedgerSnapshot {
        let now = Date()
        if !forceScan,
           let cached = self.cachedSnapshot,
           let last = self.lastScanAt,
           now.timeIntervalSince(last) < self.minScanInterval {
            return cached
        }

        do {
            let store = try self.openStore()
            let stats = try self.scan(store: store)
            let snapshot = try self.buildSnapshot(store: store, stats: stats, now: Date())
            self.cachedSnapshot = snapshot
            self.lastScanAt = now
            return snapshot
        } catch {
            self.logger.error("Codex ledger scan failed: \(error)")
            return self.cachedSnapshot ?? CodexLedgerSnapshot()
        }
    }

    /// Directories the ledger watches (for file-system event subscriptions).
    public nonisolated static func watchRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        // Watch the parent even before sessions or archived_sessions exists.
        [CodexPaths.home(environment: environment)]
    }

    static func sessionsRoot(environment: [String: String]) -> URL {
        CodexPaths.sessionRoots(environment: environment)[0]
    }

    // MARK: - Store

    private func openStore() throws -> LedgerStore {
        if let store { return store }
        let store = try LedgerStore(url: self.storeURL)
        self.store = store
        return store
    }

    // MARK: - Scanning

    private func scan(store: LedgerStore) throws -> LedgerScanStats {
        let started = Date()
        let files = CodexPaths.sessionRoots(environment: self.environment)
            .flatMap { TokenLedger.transcriptFiles(in: $0) }
            .sorted { $0.url.path < $1.url.path }
        let paths = Set(files.map { $0.url.path })
        var cursors = try store.allCursors()
        let isInitialScan = cursors.isEmpty

        // Removing or rewriting the owner of a dedup key requires replaying
        // retained files so copied history still has exactly one owner.
        if !Set(cursors.keys).isSubset(of: paths) || files.contains(where: {
            guard let cursor = cursors[$0.url.path] else { return false }
            return $0.size < cursor.offset || ($0.size == cursor.size && $0.mtime != cursor.mtime)
        }) {
            for path in cursors.keys { try store.resetFile(path: path) }
            cursors = [:]
        }

        var filesSeen = 0
        var filesParsed = 0
        var bytesParsed: Int64 = 0
        var entriesAdded = 0
        var existingPaths: Set<String> = []

        let cutoff = started.addingTimeInterval(-Double(self.historyCutoffDays) * 86400).timeIntervalSince1970

        for file in files {
            filesSeen += 1
            existingPaths.insert(file.url.path)

            let cursor = cursors[file.url.path]

            if let cursor, cursor.size == file.size, cursor.mtime == file.mtime {
                continue
            }

            // Old, never-seen file: cursor-mark without parsing (rollouts
            // are append-only, so nothing in the window is skipped).
            if cursor == nil, file.mtime < cutoff {
                try store.commit(
                    path: file.url.path, source: "codex", project: "",
                    entries: [], size: file.size, mtime: file.mtime, offset: file.size
                )
                continue
            }

            var parseFrom: Int64 = 0
            var lastTotal: Int64 = 0
            var model = CodexSessionIngestor.defaultModel
            if let cursor {
                if file.size >= cursor.offset {
                    parseFrom = cursor.offset
                    lastTotal = cursor.auxInt
                    if !cursor.auxText.isEmpty { model = cursor.auxText }
                } else {
                    try store.resetFile(path: file.url.path)
                }
            }

            do {
                let result = try CodexSessionIngestor.parse(
                    fileURL: file.url,
                    from: parseFrom,
                    lastTotalTokens: lastTotal,
                    model: model
                )
                let accepted = try store.commit(
                    path: file.url.path,
                    source: result.source?.rawValue ?? cursor?.source ?? UsageSource.codexOther.rawValue,
                    project: result.cwd ?? cursor?.project ?? "",
                    entries: result.entries,
                    size: file.size,
                    mtime: file.mtime,
                    offset: result.newOffset,
                    auxInt: result.lastTotalTokens,
                    auxText: result.model
                )
                filesParsed += 1
                bytesParsed += result.bytesRead
                entriesAdded += accepted
            } catch {
                self.logger.warning("Failed to ingest \(file.url.lastPathComponent): \(error)")
            }

        }

        try store.purgeMissingFiles(existingPaths: existingPaths)

        return LedgerScanStats(
            filesSeen: filesSeen,
            filesParsed: filesParsed,
            bytesParsed: bytesParsed,
            entriesAdded: entriesAdded,
            duration: Date().timeIntervalSince(started),
            isInitialScan: isInitialScan
        )
    }

    // MARK: - Snapshot building

    private func buildSnapshot(store: LedgerStore, stats: LedgerScanStats, now: Date) throws -> CodexLedgerSnapshot {
        let since = Int64(now.timeIntervalSince1970) - Int64(self.activityDays + 1) * 86400
        return CodexAnalytics.build(rows: try store.hourRows(since: since), stats: stats, now: now)
    }

    public func dayDetail(date: String) async -> LedgerDayDetail? {
        guard let start = TokenLedger.parseDayKey(date),
              let store = try? self.openStore(),
              let rows = try? store.hourRows(since: Int64(start.timeIntervalSince1970) - 86400) else { return nil }
        return CodexAnalytics.dayDetail(rows: rows, date: date)
    }
}
