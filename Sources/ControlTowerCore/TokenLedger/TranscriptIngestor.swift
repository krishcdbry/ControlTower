import Foundation

/// One assistant-message usage record parsed from a transcript line.
struct ParsedUsageEntry: Sendable {
    /// "messageId:requestId" when both are present; nil disables dedup for this entry.
    let dedupKey: String?
    /// UTC epoch seconds floored to the hour.
    let hourStart: Int64
    /// Normalized model id (lowercased, "[1m]" suffix stripped).
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWrite5mTokens: Int
    let cacheWrite1hTokens: Int
}

/// Result of incrementally parsing a transcript file.
struct TranscriptParseResult: Sendable {
    let entries: [ParsedUsageEntry]
    /// Byte offset just past the last complete line consumed. Resume from here next time.
    let newOffset: Int64
    /// First `cwd` value seen in the parsed region, if any.
    let cwd: String?
    let bytesRead: Int64
}

/// Streaming, incremental JSONL transcript parser.
///
/// Reads only the bytes after `offset`, splits on newlines (carrying any
/// trailing partial line so files being actively written are safe to tail),
/// and JSON-decodes only lines that pass a cheap byte-level prefilter.
enum TranscriptIngestor {
    private static let chunkSize = 1 << 20 // 1 MiB

    // Byte patterns for the prefilter.
    private static let assistantPattern = Array(#""type":"assistant""#.utf8)
    private static let usagePattern = Array(#""usage""#.utf8)
    private static let cwdPattern = Array(#""cwd""#.utf8)

    static func parse(fileURL: URL, from offset: Int64) throws -> TranscriptParseResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset))
        }

        var entries: [ParsedUsageEntry] = []
        var cwd: String?
        var carry = Data()
        var consumed: Int64 = offset
        var bytesRead: Int64 = 0
        // Memoized "yyyy-MM-ddTHH" prefix -> hour epoch.
        var hourCache: [String: Int64] = [:]

        while true {
            guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            bytesRead += Int64(chunk.count)
            carry.append(chunk)

            // Process complete lines in `carry`.
            var lineStart = carry.startIndex
            while let newlineIndex = carry[lineStart...].firstIndex(of: 0x0A) {
                let line = carry[lineStart..<newlineIndex]
                Self.processLine(line, entries: &entries, cwd: &cwd, hourCache: &hourCache)
                consumed += Int64(newlineIndex - lineStart + 1)
                lineStart = carry.index(after: newlineIndex)
            }
            carry = Data(carry[lineStart...])
        }

        return TranscriptParseResult(entries: entries, newOffset: consumed, cwd: cwd, bytesRead: bytesRead)
    }

    // MARK: - Line processing

    private static func processLine(
        _ line: Data,
        entries: inout [ParsedUsageEntry],
        cwd: inout String?,
        hourCache: inout [String: Int64]
    ) {
        guard !line.isEmpty else { return }

        // Capture project cwd from the first line that has one (cheap byte scan).
        if cwd == nil, Self.contains(line, pattern: Self.cwdPattern) {
            cwd = Self.extractCwd(line)
        }

        // Only assistant messages with usage are interesting.
        guard Self.contains(line, pattern: Self.assistantPattern),
              Self.contains(line, pattern: Self.usagePattern) else {
            return
        }

        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return
        }

        guard let timestamp = obj["timestamp"] as? String,
              let hourStart = Self.hourEpoch(fromTimestamp: timestamp, cache: &hourCache) else {
            return
        }

        guard let rawModel = message["model"] as? String else { return }
        let model = Self.normalizeModel(rawModel)
        guard !model.isEmpty, model != "<synthetic>" else { return }

        let input = Self.intValue(usage["input_tokens"])
        let output = Self.intValue(usage["output_tokens"])
        let cacheRead = Self.intValue(usage["cache_read_input_tokens"])
        let cacheWriteTotal = Self.intValue(usage["cache_creation_input_tokens"])

        // Cache-write TTL breakdown when the detail object is present.
        var cacheWrite5m = cacheWriteTotal
        var cacheWrite1h = 0
        if let detail = usage["cache_creation"] as? [String: Any] {
            let detail5m = Self.intValue(detail["ephemeral_5m_input_tokens"])
            let detail1h = Self.intValue(detail["ephemeral_1h_input_tokens"])
            if detail5m + detail1h > 0 {
                cacheWrite1h = detail1h
                // Attribute any remainder (total minus known 1h) to 5m.
                cacheWrite5m = max(0, cacheWriteTotal - detail1h)
            }
        }

        guard input > 0 || output > 0 || cacheRead > 0 || cacheWriteTotal > 0 else { return }

        // Dedup only when both ids exist (streamed chunks repeat the same pair).
        var dedupKey: String?
        if let messageID = message["id"] as? String,
           let requestID = obj["requestId"] as? String {
            dedupKey = "\(messageID):\(requestID)"
        }

        entries.append(ParsedUsageEntry(
            dedupKey: dedupKey,
            hourStart: hourStart,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWrite5mTokens: cacheWrite5m,
            cacheWrite1hTokens: cacheWrite1h
        ))
    }

    // MARK: - Helpers

    static func normalizeModel(_ raw: String) -> String {
        var model = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let bracket = model.firstIndex(of: "[") {
            model = String(model[..<bracket])
        }
        return model
    }

    private static func intValue(_ value: Any?) -> Int {
        if let intVal = value as? Int { return intVal }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func contains(_ data: Data, pattern: [UInt8]) -> Bool {
        data.range(of: Data(pattern)) != nil
    }

    /// Extracts the value of `"cwd":"..."` with a minimal scan (no full JSON decode for non-usage lines).
    private static func extractCwd(_ line: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return obj["cwd"] as? String
    }

    /// Converts an ISO-8601 UTC timestamp ("2026-06-10T07:33:01.712Z") to an
    /// hour-floored epoch using pure integer math, memoized per "yyyy-MM-ddTHH" prefix.
    static func hourEpoch(fromTimestamp timestamp: String, cache: inout [String: Int64]) -> Int64? {
        guard timestamp.count >= 13 else { return nil }
        let prefix = String(timestamp.prefix(13))
        if let cached = cache[prefix] {
            return cached
        }

        let bytes = Array(prefix.utf8)
        // Expected layout: yyyy-MM-ddTHH
        guard bytes.count == 13, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " ") else {
            return Self.slowHourEpoch(timestamp, cache: &cache, prefix: prefix)
        }

        func digit(_ index: Int) -> Int? {
            let byte = bytes[index]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            return Int(byte - 0x30)
        }

        guard let y1 = digit(0), let y2 = digit(1), let y3 = digit(2), let y4 = digit(3),
              let m1 = digit(5), let m2 = digit(6),
              let d1 = digit(8), let d2 = digit(9),
              let h1 = digit(11), let h2 = digit(12) else {
            return Self.slowHourEpoch(timestamp, cache: &cache, prefix: prefix)
        }

        let year = y1 * 1000 + y2 * 100 + y3 * 10 + y4
        let month = m1 * 10 + m2
        let day = d1 * 10 + d2
        let hour = h1 * 10 + h2
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour) else {
            return Self.slowHourEpoch(timestamp, cache: &cache, prefix: prefix)
        }

        let epoch = Int64(Self.daysFromCivil(year: year, month: month, day: day)) * 86400 + Int64(hour) * 3600
        cache[prefix] = epoch
        return epoch
    }

    /// Fallback for unusual timestamp formats (e.g. numeric offsets).
    private static func slowHourEpoch(_ timestamp: String, cache: inout [String: Int64], prefix: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: timestamp)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: timestamp)
        }
        guard let parsed = date else { return nil }
        let epoch = Int64(parsed.timeIntervalSince1970 / 3600) * 3600
        cache[prefix] = epoch
        return epoch
    }

    /// Howard Hinnant's days-from-civil algorithm: days since 1970-01-01 for a proleptic Gregorian date.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
