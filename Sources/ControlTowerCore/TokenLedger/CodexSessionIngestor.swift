import Foundation

/// Result of incrementally parsing a Codex rollout file.
struct CodexParseResult: Sendable {
    let entries: [ParsedUsageEntry]
    /// Byte offset just past the last complete line consumed.
    let newOffset: Int64
    /// Cumulative `total_token_usage.total_tokens` after the parsed region
    /// (persisted in the cursor's `auxInt` so duplicate heartbeats spanning
    /// scan boundaries are still skipped).
    let lastTotalTokens: Int64
    /// Model in effect at the end of the parsed region (cursor `auxText`).
    let model: String
    /// Working directory from session metadata, if seen.
    let cwd: String?
    let bytesRead: Int64
}

/// Streaming, incremental parser for Codex CLI rollout files
/// (~/.codex/sessions/**/rollout-*.jsonl).
///
/// Codex emits `token_count` events whose `info.total_token_usage` is
/// *cumulative* for the session and `info.last_token_usage` is the per-turn
/// delta. Only deltas are summed, and an event is counted only when the
/// cumulative total advances — heartbeat re-emissions of the same state are
/// skipped. Verified against real rollouts: `cached_input_tokens` is a subset
/// of `input_tokens`, `reasoning_output_tokens` a subset of `output_tokens`,
/// and `total_tokens == input + output`.
///
/// Column mapping into `LedgerStore` (shared schema, separate database):
///   input      -> non-cached input tokens (input - cached)
///   cache_read -> cached input tokens
///   output     -> output tokens (reasoning included)
///   cache_w5m  -> reasoning tokens (informational subset; excluded from totals)
///   cache_w1h  -> unused (0)
enum CodexSessionIngestor {
    private static let chunkSize = 1 << 20

    private static let tokenUsagePattern = Array(#""total_token_usage""#.utf8)
    private static let turnContextPattern = Array(#""type":"turn_context""#.utf8)
    private static let sessionMetaPattern = Array(#""type":"session_meta""#.utf8)

    static let defaultModel = "gpt-5.1-codex"

    static func parse(
        fileURL: URL,
        from offset: Int64,
        lastTotalTokens: Int64,
        model initialModel: String
    ) throws -> CodexParseResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset))
        }

        var entries: [ParsedUsageEntry] = []
        var carry = Data()
        var consumed: Int64 = offset
        var bytesRead: Int64 = 0
        var lastTotal = lastTotalTokens
        var model = initialModel.isEmpty ? Self.defaultModel : initialModel
        var cwd: String?
        var hourCache: [String: Int64] = [:]

        while true {
            guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            bytesRead += Int64(chunk.count)
            carry.append(chunk)

            var lineStart = carry.startIndex
            while let newlineIndex = carry[lineStart...].firstIndex(of: 0x0A) {
                let line = carry[lineStart..<newlineIndex]
                Self.processLine(
                    line,
                    entries: &entries,
                    lastTotal: &lastTotal,
                    model: &model,
                    cwd: &cwd,
                    hourCache: &hourCache
                )
                consumed += Int64(newlineIndex - lineStart + 1)
                lineStart = carry.index(after: newlineIndex)
            }
            carry = Data(carry[lineStart...])
        }

        return CodexParseResult(
            entries: entries,
            newOffset: consumed,
            lastTotalTokens: lastTotal,
            model: model,
            cwd: cwd,
            bytesRead: bytesRead
        )
    }

    // MARK: - Line processing

    private static func processLine(
        _ line: Data,
        entries: inout [ParsedUsageEntry],
        lastTotal: inout Int64,
        model: inout String,
        cwd: inout String?,
        hourCache: inout [String: Int64]
    ) {
        guard !line.isEmpty else { return }

        // Track the active model from turn context (cheap byte prefilter first).
        if Self.contains(line, pattern: Self.turnContextPattern) {
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let payload = obj["payload"] as? [String: Any],
               let contextModel = payload["model"] as? String, !contextModel.isEmpty {
                model = contextModel.lowercased()
                if cwd == nil { cwd = payload["cwd"] as? String }
            }
            return
        }

        // Project attribution from session metadata.
        if cwd == nil, Self.contains(line, pattern: Self.sessionMetaPattern) {
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let payload = obj["payload"] as? [String: Any] {
                cwd = payload["cwd"] as? String
            }
            return
        }

        guard Self.contains(line, pattern: Self.tokenUsagePattern) else { return }

        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any],
              let totalUsage = info["total_token_usage"] as? [String: Any] else {
            return
        }

        // Count an event only when the session's cumulative total advances.
        let total = Int64(Self.intValue(totalUsage["total_tokens"]))
        guard total != lastTotal else { return }
        if total < lastTotal {
            // Cumulative totals never decrease in append-only rollouts;
            // treat a regression as a new baseline without counting it.
            lastTotal = total
            return
        }
        lastTotal = total

        // The per-turn delta is authoritative for what this event added.
        guard let lastUsage = info["last_token_usage"] as? [String: Any] else { return }

        guard let timestamp = obj["timestamp"] as? String,
              let hourStart = TranscriptIngestor.hourEpoch(fromTimestamp: timestamp, cache: &hourCache) else {
            return
        }

        let input = Self.intValue(lastUsage["input_tokens"])
        let cached = min(Self.intValue(lastUsage["cached_input_tokens"]), input)
        let output = Self.intValue(lastUsage["output_tokens"])
        let reasoning = min(Self.intValue(lastUsage["reasoning_output_tokens"]), output)

        guard input > 0 || output > 0 else { return }

        entries.append(ParsedUsageEntry(
            dedupKey: nil, // monotonic-total check above is the dedup
            hourStart: hourStart,
            model: model,
            inputTokens: input - cached,
            outputTokens: output,
            cacheReadTokens: cached,
            cacheWrite5mTokens: reasoning,
            cacheWrite1hTokens: 0
        ))
    }

    private static func intValue(_ value: Any?) -> Int {
        if let intVal = value as? Int { return intVal }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func contains(_ data: Data, pattern: [UInt8]) -> Bool {
        data.range(of: Data(pattern)) != nil
    }
}
