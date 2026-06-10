import Foundation
import Logging

/// One local day of Codex usage.
public struct CodexLedgerDay: Sendable, Equatable {
    public let date: String // yyyy-MM-dd, local timezone
    public let inputTokens: Int // non-cached input
    public let cachedInputTokens: Int
    public let outputTokens: Int // includes reasoning
    public let reasoningTokens: Int // informational subset of output
    public let costUSD: Double

    /// Billable token volume (input + cached + output; reasoning is already inside output).
    public var totalTokens: Int { self.inputTokens + self.cachedInputTokens + self.outputTokens }
}

/// Snapshot of Codex usage aggregates.
public struct CodexLedgerSnapshot: Sendable {
    public let generatedAt: Date
    /// Last 30 local days, ascending by date.
    public let days: [CodexLedgerDay]
    public let stats: LedgerScanStats

    public init(generatedAt: Date = Date(), days: [CodexLedgerDay] = [], stats: LedgerScanStats = LedgerScanStats()) {
        self.generatedAt = generatedAt
        self.days = days
        self.stats = stats
    }
}

/// Incremental token tracker for Codex CLI sessions, mirroring `TokenLedger`:
/// per-file byte cursors, monotonic-total dedup, hour aggregates in SQLite,
/// priced at query time. Steady-state scans are a stat pass over the roots.
public actor CodexLedger {
    public static let shared = CodexLedger()

    private let logger = Logger(label: "com.controltower.codexledger")
    private let storeURL: URL
    private var store: LedgerStore?

    private var cachedSnapshot: CodexLedgerSnapshot?
    private var lastScanAt: Date?
    private let minScanInterval: TimeInterval = 5
    private let historyCutoffDays = 35
    private let windowDays = 30

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? Self.defaultStoreURL()
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
            let stats = try await self.scan(store: store)
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
        [Self.sessionsRoot(environment: environment)].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    static func sessionsRoot(environment: [String: String]) -> URL {
        if let envPath = environment["CODEX_HOME"], !envPath.isEmpty {
            return URL(fileURLWithPath: envPath).appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    // MARK: - Store

    private func openStore() throws -> LedgerStore {
        if let store { return store }
        let store = try LedgerStore(url: self.storeURL)
        self.store = store
        return store
    }

    // MARK: - Scanning

    private func scan(store: LedgerStore) async throws -> LedgerScanStats {
        let started = Date()
        let roots = Self.watchRoots(environment: ProcessInfo.processInfo.environment)
        let cursors = try store.allCursors()
        let isInitialScan = cursors.isEmpty

        var filesSeen = 0
        var filesParsed = 0
        var bytesParsed: Int64 = 0
        var entriesAdded = 0
        var existingPaths: Set<String> = []

        let cutoff = started.addingTimeInterval(-Double(self.historyCutoffDays) * 86400).timeIntervalSince1970

        for root in roots {
            for file in TokenLedger.transcriptFiles(in: root) {
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
                        source: "codex",
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

                if filesParsed % 16 == 0 {
                    await Task.yield()
                }
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
        let since = Int64(now.timeIntervalSince1970) - Int64(self.windowDays + 1) * 86400
        let rows = try store.hourRows(since: since)

        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let todayKey = TokenLedger.dayKey(for: now, calendar: calendar)
        let last30Start = TokenLedger.dayKey(
            for: now.addingTimeInterval(-Double(self.windowDays - 1) * 86400),
            calendar: calendar
        )

        struct DayBucket {
            var input = 0
            var cached = 0
            var output = 0
            var reasoning = 0
            var cost: Double = 0
        }
        var dayBuckets: [String: DayBucket] = [:]
        var dayKeyCache: [Int64: String] = [:]

        for row in rows {
            let dayKey: String
            if let cached = dayKeyCache[row.hourStart] {
                dayKey = cached
            } else {
                dayKey = TokenLedger.dayKey(
                    for: Date(timeIntervalSince1970: TimeInterval(row.hourStart)),
                    calendar: calendar
                )
                dayKeyCache[row.hourStart] = dayKey
            }
            guard dayKey >= last30Start, dayKey <= todayKey else { continue }

            // Column mapping documented in CodexSessionIngestor:
            // input = non-cached input, cache_read = cached, cache_w5m = reasoning.
            let cost = CodexPricing.cost(
                model: row.model,
                inputTokens: row.inputTokens,
                cachedInputTokens: row.cacheReadTokens,
                outputTokens: row.outputTokens
            )
            var bucket = dayBuckets[dayKey] ?? DayBucket()
            bucket.input += row.inputTokens
            bucket.cached += row.cacheReadTokens
            bucket.output += row.outputTokens
            bucket.reasoning += row.cacheWrite5mTokens
            bucket.cost += cost
            dayBuckets[dayKey] = bucket
        }

        let days = dayBuckets.keys.sorted().compactMap { key -> CodexLedgerDay? in
            guard let bucket = dayBuckets[key] else { return nil }
            return CodexLedgerDay(
                date: key,
                inputTokens: bucket.input,
                cachedInputTokens: bucket.cached,
                outputTokens: bucket.output,
                reasoningTokens: bucket.reasoning,
                costUSD: bucket.cost
            )
        }

        return CodexLedgerSnapshot(generatedAt: now, days: days, stats: stats)
    }
}
