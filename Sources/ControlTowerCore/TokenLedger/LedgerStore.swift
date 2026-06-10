import Foundation
import GRDB

/// Per-file ingestion cursor.
///
/// `auxInt`/`auxText` carry parser state that must survive across incremental
/// scans; their meaning is provider-specific (the Claude ingestor leaves them
/// at defaults; the Codex ingestor stores the last cumulative token total and
/// the session's current model).
struct LedgerFileCursor: Sendable, Equatable {
    let path: String
    let size: Int64
    let mtime: Double
    let offset: Int64
    let source: String
    let project: String
    var auxInt: Int64 = 0
    var auxText: String = ""
}

/// One (hour, model, source, project) aggregate row.
struct LedgerHourRow: Sendable {
    let hourStart: Int64
    let model: String
    let source: String
    let project: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWrite5mTokens: Int
    let cacheWrite1hTokens: Int
    let entryCount: Int
}

/// SQLite-backed store for the token ledger: file cursors, a global dedup
/// set, and per-(file, hour, model) usage aggregates.
///
/// Deduplication is global across files (resumed/forked sessions repeat
/// usage lines in multiple transcripts), keyed by messageId:requestId.
/// When a file is re-ingested from scratch its aggregates and owned dedup
/// keys are removed first, so totals stay correct.
final class LedgerStore: Sendable {
    private let dbQueue: DatabaseQueue

    static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ControlTower", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("token-ledger.sqlite")
    }

    init(url: URL) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try self.migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("ledger_v1") { db in
            try db.create(table: "file_cursor") { t in
                t.column("path", .text).primaryKey()
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("offset", .integer).notNull()
                t.column("source", .text).notNull()
                t.column("project", .text).notNull().defaults(to: "")
            }

            try db.create(table: "dedup_keys") { t in
                t.column("key", .text).primaryKey()
                t.column("path", .text).notNull()
            }
            try db.create(index: "idx_dedup_path", on: "dedup_keys", columns: ["path"])

            try db.create(table: "usage_hours") { t in
                t.column("path", .text).notNull()
                t.column("hour_start", .integer).notNull()
                t.column("model", .text).notNull()
                t.column("source", .text).notNull()
                t.column("project", .text).notNull().defaults(to: "")
                t.column("input", .integer).notNull().defaults(to: 0)
                t.column("output", .integer).notNull().defaults(to: 0)
                t.column("cache_read", .integer).notNull().defaults(to: 0)
                t.column("cache_w5m", .integer).notNull().defaults(to: 0)
                t.column("cache_w1h", .integer).notNull().defaults(to: 0)
                t.column("entries", .integer).notNull().defaults(to: 0)
                t.primaryKey(["path", "hour_start", "model"])
            }
            try db.create(index: "idx_usage_hours_hour", on: "usage_hours", columns: ["hour_start"])
        }

        // v2: provider-specific cursor state (see LedgerFileCursor).
        migrator.registerMigration("ledger_v2_cursor_aux") { db in
            try db.alter(table: "file_cursor") { t in
                t.add(column: "aux_int", .integer).notNull().defaults(to: 0)
                t.add(column: "aux_text", .text).notNull().defaults(to: "")
            }
        }

        // v3: history window widened from 35 to 190 days for the activity
        // heatmap. Files outside the old window were cursor-marked without
        // parsing, so a one-time full re-index is required.
        migrator.registerMigration("ledger_v3_reindex_history") { db in
            try db.execute(sql: "DELETE FROM usage_hours")
            try db.execute(sql: "DELETE FROM dedup_keys")
            try db.execute(sql: "DELETE FROM file_cursor")
        }

        try migrator.migrate(self.dbQueue)
    }

    // MARK: - Cursors

    func allCursors() throws -> [String: LedgerFileCursor] {
        try self.dbQueue.read { db in
            var result: [String: LedgerFileCursor] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT path, size, mtime, offset, source, project, aux_int, aux_text FROM file_cursor"
            )
            for row in rows {
                let cursor = LedgerFileCursor(
                    path: row["path"],
                    size: row["size"],
                    mtime: row["mtime"],
                    offset: row["offset"],
                    source: row["source"],
                    project: row["project"],
                    auxInt: row["aux_int"],
                    auxText: row["aux_text"]
                )
                result[cursor.path] = cursor
            }
            return result
        }
    }

    /// Removes a file's aggregates, owned dedup keys, and cursor (before a from-scratch re-ingest).
    func resetFile(path: String) throws {
        try self.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM usage_hours WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM dedup_keys WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM file_cursor WHERE path = ?", arguments: [path])
        }
    }

    /// Removes records for files that no longer exist on disk.
    func purgeMissingFiles(existingPaths: Set<String>) throws {
        let stored = try self.allCursors()
        let missing = stored.keys.filter { !existingPaths.contains($0) }
        guard !missing.isEmpty else { return }
        try self.dbQueue.write { db in
            for path in missing {
                try db.execute(sql: "DELETE FROM usage_hours WHERE path = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM dedup_keys WHERE path = ?", arguments: [path])
                try db.execute(sql: "DELETE FROM file_cursor WHERE path = ?", arguments: [path])
            }
        }
    }

    // MARK: - Ingestion

    /// Commits parsed entries for one file atomically: global dedup,
    /// hour-aggregate upserts, and the cursor update happen in one transaction.
    /// Returns the number of entries that survived dedup.
    @discardableResult
    func commit(
        path: String,
        source: String,
        project: String,
        entries: [ParsedUsageEntry],
        size: Int64,
        mtime: Double,
        offset: Int64,
        auxInt: Int64 = 0,
        auxText: String = ""
    ) throws -> Int {
        try self.dbQueue.write { db in
            var accepted = 0
            // (hourStart, model) -> aggregate
            var aggregates: [HourKey: Aggregate] = [:]

            for entry in entries {
                if let key = entry.dedupKey {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO dedup_keys(key, path) VALUES (?, ?)",
                        arguments: [key, path]
                    )
                    if db.changesCount == 0 { continue } // duplicate
                }
                accepted += 1
                let key = HourKey(hourStart: entry.hourStart, model: entry.model)
                aggregates[key, default: Aggregate()].add(entry)
            }

            for (key, agg) in aggregates {
                try db.execute(
                    sql: """
                    INSERT INTO usage_hours(path, hour_start, model, source, project, input, output, cache_read, cache_w5m, cache_w1h, entries)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path, hour_start, model) DO UPDATE SET
                        input = input + excluded.input,
                        output = output + excluded.output,
                        cache_read = cache_read + excluded.cache_read,
                        cache_w5m = cache_w5m + excluded.cache_w5m,
                        cache_w1h = cache_w1h + excluded.cache_w1h,
                        entries = entries + excluded.entries,
                        source = excluded.source,
                        project = excluded.project
                    """,
                    arguments: [
                        path, key.hourStart, key.model, source, project,
                        agg.input, agg.output, agg.cacheRead, agg.cacheW5m, agg.cacheW1h, agg.entries,
                    ]
                )
            }

            try db.execute(
                sql: """
                INSERT INTO file_cursor(path, size, mtime, offset, source, project, aux_int, aux_text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    size = excluded.size,
                    mtime = excluded.mtime,
                    offset = excluded.offset,
                    source = excluded.source,
                    project = CASE WHEN excluded.project != '' THEN excluded.project ELSE file_cursor.project END,
                    aux_int = excluded.aux_int,
                    aux_text = excluded.aux_text
                """,
                arguments: [path, size, mtime, offset, source, project, auxInt, auxText]
            )

            return accepted
        }
    }

    // MARK: - Queries

    /// All hour aggregates at or after `since` (UTC epoch seconds).
    func hourRows(since: Int64) throws -> [LedgerHourRow] {
        try self.dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT hour_start, model, source, project,
                       SUM(input) AS input, SUM(output) AS output, SUM(cache_read) AS cache_read,
                       SUM(cache_w5m) AS cache_w5m, SUM(cache_w1h) AS cache_w1h, SUM(entries) AS entries
                FROM usage_hours
                WHERE hour_start >= ?
                GROUP BY hour_start, model, source, project
                ORDER BY hour_start ASC
                """,
                arguments: [since]
            )
            return rows.map { row in
                LedgerHourRow(
                    hourStart: row["hour_start"],
                    model: row["model"],
                    source: row["source"],
                    project: row["project"],
                    inputTokens: row["input"],
                    outputTokens: row["output"],
                    cacheReadTokens: row["cache_read"],
                    cacheWrite5mTokens: row["cache_w5m"],
                    cacheWrite1hTokens: row["cache_w1h"],
                    entryCount: row["entries"]
                )
            }
        }
    }

    // MARK: - Private helpers

    private struct HourKey: Hashable {
        let hourStart: Int64
        let model: String
    }

    private struct Aggregate {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheW5m = 0
        var cacheW1h = 0
        var entries = 0

        mutating func add(_ entry: ParsedUsageEntry) {
            self.input += entry.inputTokens
            self.output += entry.outputTokens
            self.cacheRead += entry.cacheReadTokens
            self.cacheW5m += entry.cacheWrite5mTokens
            self.cacheW1h += entry.cacheWrite1hTokens
            self.entries += 1
        }
    }
}
