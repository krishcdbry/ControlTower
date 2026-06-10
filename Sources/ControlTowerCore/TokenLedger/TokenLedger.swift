import Foundation
import Logging

/// High-performance local token tracker for all Claude apps.
///
/// Ingests Claude Code / Claude Desktop / Cowork transcripts (JSONL files in
/// ~/.claude/projects and friends) incrementally: each file has a persisted
/// byte cursor, so steady-state scans only stat files and parse appended
/// bytes. Usage is deduplicated globally (messageId:requestId), aggregated
/// per hour/model/source/project in SQLite, and priced at query time so
/// pricing updates retroactively correct history.
public actor TokenLedger {
    public static let shared = TokenLedger()

    private let logger = Logger(label: "com.controltower.tokenledger")
    private let storeURL: URL
    private var store: LedgerStore?

    private var cachedSnapshot: LedgerSnapshot?
    private var lastScanAt: Date?
    /// Steady-state scans are cheap (a stat pass), so the floor is low.
    private let minScanInterval: TimeInterval = 5

    /// Files whose mtime is older than this never contain entries inside the
    /// reporting window (transcripts are append-only), so they are cursor-marked
    /// without parsing. Keeps cold start proportional to recent activity.
    private let historyCutoffDays = 35
    /// Reporting window for snapshot aggregates.
    private let windowDays = 30

    private var desktopSessionIDs: Set<String> = []
    private var desktopCatalogLoadedAt: Date?

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? LedgerStore.defaultURL()
    }

    // MARK: - Public API

    /// Returns the current snapshot, scanning for transcript changes first
    /// (incremental; steady-state cost is a stat pass over the roots).
    public func snapshot(forceScan: Bool = false) async -> LedgerSnapshot {
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
            self.logger.error("Token ledger scan failed: \(error)")
            return self.cachedSnapshot ?? LedgerSnapshot()
        }
    }

    /// Directories the ledger watches (for file-system event subscriptions).
    public nonisolated static func watchRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        Self.projectsRoots(environment: environment)
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
        let roots = Self.projectsRoots(environment: ProcessInfo.processInfo.environment)
        let cursors = try store.allCursors()
        let isInitialScan = cursors.isEmpty

        self.refreshDesktopCatalogIfNeeded()

        var filesSeen = 0
        var filesParsed = 0
        var bytesParsed: Int64 = 0
        var entriesAdded = 0
        var existingPaths: Set<String> = []

        let cutoff = started.addingTimeInterval(-Double(self.historyCutoffDays) * 86400).timeIntervalSince1970

        for root in roots {
            let files = Self.transcriptFiles(in: root)
            for file in files {
                filesSeen += 1
                existingPaths.insert(file.url.path)

                let cursor = cursors[file.url.path]

                // Unchanged since last scan.
                if let cursor, cursor.size == file.size, cursor.mtime == file.mtime {
                    continue
                }

                let source = self.resolveSource(for: file.url)

                // Old file never seen before: mark ingested without parsing.
                // Append-only transcripts can't contain entries newer than mtime,
                // so nothing inside the reporting window is skipped.
                if cursor == nil, file.mtime < cutoff {
                    try store.commit(
                        path: file.url.path, source: source.rawValue, project: "",
                        entries: [], size: file.size, mtime: file.mtime, offset: file.size
                    )
                    continue
                }

                var parseFrom: Int64 = 0
                if let cursor {
                    if file.size >= cursor.offset {
                        parseFrom = cursor.offset
                    } else {
                        // Truncated or rewritten: drop prior contributions and re-ingest.
                        try store.resetFile(path: file.url.path)
                    }
                }

                do {
                    let result = try TranscriptIngestor.parse(fileURL: file.url, from: parseFrom)
                    let project = result.cwd ?? cursor?.project ?? ""
                    let accepted = try store.commit(
                        path: file.url.path,
                        source: source.rawValue,
                        project: project,
                        entries: result.entries,
                        size: file.size,
                        mtime: file.mtime,
                        offset: result.newOffset
                    )
                    filesParsed += 1
                    bytesParsed += result.bytesRead
                    entriesAdded += accepted
                } catch {
                    self.logger.warning("Failed to ingest \(file.url.lastPathComponent): \(error)")
                }

                // Keep the actor responsive during large cold scans.
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

    // MARK: - Source attribution

    private func refreshDesktopCatalogIfNeeded() {
        let now = Date()
        if let loaded = self.desktopCatalogLoadedAt, now.timeIntervalSince(loaded) < 60 {
            return
        }
        self.desktopSessionIDs = DesktopSessionCatalog.desktopSessionIDs()
        self.desktopCatalogLoadedAt = now
    }

    private func resolveSource(for fileURL: URL) -> UsageSource {
        let projectDir = fileURL.deletingLastPathComponent().lastPathComponent
        if projectDir.hasSuffix("ControlTower-ClaudeProbe") {
            return .probe
        }
        let sessionID = fileURL.deletingPathExtension().lastPathComponent.lowercased()
        if self.desktopSessionIDs.contains(sessionID) {
            return .claudeDesktop
        }
        return .claudeCode
    }

    // MARK: - Snapshot building

    private func buildSnapshot(store: LedgerStore, stats: LedgerScanStats, now: Date) throws -> LedgerSnapshot {
        // One extra day of lookback so local-timezone day bucketing is complete.
        let since = Int64(now.timeIntervalSince1970) - Int64(self.windowDays + 1) * 86400
        let rows = try store.hourRows(since: since)

        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current

        // Local day keys for the reporting window.
        let todayKey = Self.dayKey(for: now, calendar: calendar)
        let last7Start = Self.dayKey(for: now.addingTimeInterval(-6 * 86400), calendar: calendar)
        let last30Start = Self.dayKey(for: now.addingTimeInterval(-Double(self.windowDays - 1) * 86400), calendar: calendar)

        var dayKeyCache: [Int64: String] = [:]

        struct DayBucket {
            var totals = TokenTotals.zero
            var byModel: [String: TokenTotals] = [:]
            var bySource: [UsageSource: TokenTotals] = [:]
        }
        var dayBuckets: [String: DayBucket] = [:]
        var bySource: [UsageSource: TokenTotals] = [:]
        var byModel: [String: TokenTotals] = [:]
        var byProject: [String: TokenTotals] = [:]

        // Hour buckets for block computation (probe excluded like everything else).
        struct HourBucket {
            var totals = TokenTotals.zero
            var byModel: [String: TokenTotals] = [:]
        }
        var hourBuckets: [Int64: HourBucket] = [:]

        for row in rows {
            let source = UsageSource(rawValue: row.source) ?? .claudeCode
            guard source != .probe else { continue }

            let cost = ClaudePricing.cost(
                model: row.model,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheWrite5mTokens: row.cacheWrite5mTokens,
                cacheWrite1hTokens: row.cacheWrite1hTokens
            )
            let totals = TokenTotals(
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheWrite5mTokens: row.cacheWrite5mTokens,
                cacheWrite1hTokens: row.cacheWrite1hTokens,
                entryCount: row.entryCount,
                costUSD: cost
            )

            let dayKey: String
            if let cached = dayKeyCache[row.hourStart] {
                dayKey = cached
            } else {
                dayKey = Self.dayKey(for: Date(timeIntervalSince1970: TimeInterval(row.hourStart)), calendar: calendar)
                dayKeyCache[row.hourStart] = dayKey
            }
            guard dayKey >= last30Start, dayKey <= todayKey else { continue }

            dayBuckets[dayKey, default: DayBucket()].totals.add(totals)
            dayBuckets[dayKey]?.byModel[row.model, default: .zero].add(totals)
            dayBuckets[dayKey]?.bySource[source, default: .zero].add(totals)

            bySource[source, default: .zero].add(totals)
            byModel[row.model, default: .zero].add(totals)
            if !row.project.isEmpty {
                byProject[row.project, default: .zero].add(totals)
            }

            hourBuckets[row.hourStart, default: HourBucket()].totals.add(totals)
            hourBuckets[row.hourStart]?.byModel[row.model, default: .zero].add(totals)
        }

        // Window totals.
        var today = TokenTotals.zero
        var last7 = TokenTotals.zero
        var last30 = TokenTotals.zero
        var days: [LedgerDay] = []
        for key in dayBuckets.keys.sorted() {
            guard let bucket = dayBuckets[key] else { continue }
            days.append(LedgerDay(date: key, totals: bucket.totals, byModel: bucket.byModel, bySource: bucket.bySource))
            last30.add(bucket.totals)
            if key >= last7Start { last7.add(bucket.totals) }
            if key == todayKey { today = bucket.totals }
        }

        // 5h blocks from hour buckets.
        let blocks = Self.computeBlocks(hourBuckets: hourBuckets.mapValues { ($0.totals, $0.byModel) })
        let currentBlock = blocks.last.flatMap { $0.isActive(at: now) ? $0 : nil }

        let projects = byProject
            .map { LedgerProjectUsage(path: $0.key, totals: $0.value) }
            .sorted { $0.totals.costUSD > $1.totals.costUSD }

        return LedgerSnapshot(
            generatedAt: now,
            today: today,
            last7Days: last7,
            last30Days: last30,
            days: days,
            bySource: bySource,
            byModel: byModel,
            byProject: Array(projects.prefix(8)),
            currentBlock: currentBlock,
            recentBlocks: Array(blocks.suffix(12)),
            stats: stats
        )
    }

    /// Groups hour buckets into 5-hour blocks mirroring Anthropic's session
    /// windows: a block starts at the (UTC hour-floored) first activity,
    /// spans 5 hours, and a gap of 5+ hours starts a new block.
    static func computeBlocks(
        hourBuckets: [Int64: (TokenTotals, [String: TokenTotals])]
    ) -> [LedgerBlock] {
        let blockSeconds: Int64 = 5 * 3600
        var blocks: [LedgerBlock] = []

        var blockStart: Int64?
        var lastActive: Int64 = 0
        var totals = TokenTotals.zero
        var byModel: [String: TokenTotals] = [:]

        func close() {
            guard let start = blockStart else { return }
            blocks.append(LedgerBlock(
                start: Date(timeIntervalSince1970: TimeInterval(start)),
                end: Date(timeIntervalSince1970: TimeInterval(start + blockSeconds)),
                lastActivityHour: Date(timeIntervalSince1970: TimeInterval(lastActive)),
                totals: totals,
                byModel: byModel
            ))
            blockStart = nil
            totals = .zero
            byModel = [:]
        }

        for hour in hourBuckets.keys.sorted() {
            guard let bucket = hourBuckets[hour], bucket.0.totalTokens > 0 else { continue }

            if let start = blockStart,
               hour >= start + blockSeconds || hour >= lastActive + blockSeconds {
                close()
            }
            if blockStart == nil {
                blockStart = hour
            }
            totals.add(bucket.0)
            for (model, modelTotals) in bucket.1 {
                byModel[model, default: .zero].add(modelTotals)
            }
            lastActive = hour
        }
        close()

        return blocks
    }

    // MARK: - File discovery

    static func projectsRoots(environment: [String: String]) -> [URL] {
        var roots: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        if let envPath = environment["CLAUDE_CONFIG_DIR"], !envPath.isEmpty {
            for part in envPath.split(separator: ",") {
                let path = String(part).trimmingCharacters(in: .whitespaces)
                let url = URL(fileURLWithPath: path)
                if url.lastPathComponent == "projects" {
                    roots.append(url)
                } else {
                    roots.append(url.appendingPathComponent("projects", isDirectory: true))
                }
            }
        } else {
            roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))
            roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
        }

        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    struct TranscriptFile {
        let url: URL
        let size: Int64
        let mtime: Double
    }

    static func transcriptFiles(in root: URL) -> [TranscriptFile] {
        var files: [TranscriptFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return files }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            files.append(TranscriptFile(
                url: fileURL,
                size: Int64(values.fileSize ?? 0),
                mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        return files
    }

    // MARK: - Date helpers

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
