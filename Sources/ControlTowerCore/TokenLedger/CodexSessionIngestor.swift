import CryptoKit
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
    let source: UsageSource?
    let bytesRead: Int64
}

/// Streaming, incremental parser for Codex CLI rollout files
/// (~/.codex/sessions/**/rollout-*.jsonl).
///
/// Codex emits `token_count` events whose `info.total_token_usage` is
/// *cumulative* for the session and `info.last_token_usage` is the per-turn
/// delta. Only deltas are summed, and an event is counted only when the
/// cumulative total advances. Heartbeat re-emissions of the same state are
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
    private static let turnContextPattern = Array(#""turn_context""#.utf8)
    private static let sessionMetaPattern = Array(#""session_meta""#.utf8)
    private static let usageRecordPattern = Array(#""token_usage_record""#.utf8)

    static let defaultModel = "unknown"

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
        var source: UsageSource?
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
                    source: &source,
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
            source: source,
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
        source: inout UsageSource?,
        hourCache: inout [String: Int64]
    ) {
        guard !line.isEmpty else { return }

        // Track the active model from turn context (cheap byte prefilter first).
        if Self.contains(line, pattern: Self.turnContextPattern) {
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               obj["type"] as? String == "turn_context",
               let payload = obj["payload"] as? [String: Any],
               let contextModel = payload["model"] as? String, !contextModel.isEmpty {
                model = contextModel.lowercased()
                if cwd == nil { cwd = payload["cwd"] as? String }
            }
            return
        }

        // Project attribution from session metadata.
        if Self.contains(line, pattern: Self.sessionMetaPattern) {
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               obj["type"] as? String == "session_meta",
               let payload = obj["payload"] as? [String: Any] {
                cwd = payload["cwd"] as? String
                source = Self.usageSource(metadata: payload)
            }
            return
        }

        guard Self.contains(line, pattern: Self.tokenUsagePattern)
            || Self.contains(line, pattern: Self.usageRecordPattern) else { return }

        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else {
            return
        }

        let totalUsage: [String: Any]
        let lastUsage: [String: Any]
        let responseID: String?
        if obj["type"] as? String == "token_usage_record" {
            // Desktop writes a durable response record before its token_count
            // notification. Advancing the same baseline skips the notification.
            guard let total = payload["thread_token_usage"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any] else { return }
            totalUsage = total
            lastUsage = usage
            responseID = payload["response_id"] as? String
        } else {
            guard obj["type"] as? String == "event_msg",
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any] else { return }
            totalUsage = total
            lastUsage = usage
            responseID = nil
        }

        guard let timestamp = obj["timestamp"] as? String,
              let hourStart = Self.usageBucket(from: timestamp, cache: &hourCache) else {
            return
        }

        let input = Self.intValue(lastUsage["input_tokens"])
        let cached = min(Self.intValue(lastUsage["cached_input_tokens"]), input)
        let output = Self.intValue(lastUsage["output_tokens"])
        let reasoning = min(Self.intValue(lastUsage["reasoning_output_tokens"]), output)

        // Skip mirrored notifications. A resumed session can reset its
        // counters; then the new total is exactly the current response usage.
        let total = Int64(Self.intValue(totalUsage["total_tokens"]))
        guard total != lastTotal else { return }
        if total < lastTotal, total != Int64(input + output) { return }

        guard input > 0 || output > 0 else { return }
        lastTotal = total

        // Copied history in forks must not count again in another file.
        // Older CLI records have no response ID; fingerprint their original
        // timestamp and token counters instead of the enclosing session ID.
        let fingerprint = "\(timestamp)|\(total)|\(input)|\(cached)|\(output)|\(reasoning)"
        let dedupKey = responseID.flatMap { $0.isEmpty ? nil : "codex-response:\($0)" }
            ?? "codex-event:" + SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        entries.append(ParsedUsageEntry(
            dedupKey: dedupKey,
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
        if let intVal = value as? Int { return max(0, intVal) }
        if let number = value as? NSNumber { return max(0, number.intValue) }
        return 0
    }

    static func usageSource(metadata: [String: Any]) -> UsageSource {
        if let source = metadata["source"] as? [String: Any], source["subagent"] != nil {
            return .codexAgent
        }
        let originator = (metadata["originator"] as? String ?? "").lowercased()
        if originator.contains("desktop") { return .codexDesktop }
        switch metadata["source"] as? String {
        case "cli", "exec": return .codexCLI
        case "vscode": return .codexIDE
        default: return .codexOther
        }
    }

    // Minute buckets preserve local midnight in half-hour and quarter-hour
    // timezones. UTC hour buckets shift the first part of a day backwards.
    static func usageBucket(from timestamp: String, cache: inout [String: Int64]) -> Int64? {
        let key = timestamp.hasSuffix("Z") ? String(timestamp.prefix(16)) + "Z" : timestamp
        if let cached = cache[key] { return cached }
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: timestamp.contains("."))
        guard let date = try? Date(timestamp, strategy: style) else { return nil }
        let bucket = Int64(date.timeIntervalSince1970) / 60 * 60
        cache[key] = bucket
        return bucket
    }

    private static func contains(_ data: Data, pattern: [UInt8]) -> Bool {
        data.range(of: Data(pattern)) != nil
    }
}
