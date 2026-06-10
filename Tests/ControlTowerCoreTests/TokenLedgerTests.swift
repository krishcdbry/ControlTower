import Foundation
import Testing
@testable import ControlTowerCore

// MARK: - Pricing

@Suite("ClaudePricing Tests")
struct ClaudePricingTests {
    @Test("Modern Opus models are $5/$25")
    func modernOpusPricing() {
        for model in ["claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"] {
            let price = ClaudePricing.price(for: model)
            #expect(price.inputPerMillion == 5, "\(model) input")
            #expect(price.outputPerMillion == 25, "\(model) output")
        }
    }

    @Test("Legacy Opus models stay at $15/$75")
    func legacyOpusPricing() {
        for model in ["claude-opus-4-1", "claude-opus-4-20250514", "claude-3-opus-20240229"] {
            let price = ClaudePricing.price(for: model)
            #expect(price.inputPerMillion == 15, "\(model) input")
            #expect(price.outputPerMillion == 75, "\(model) output")
        }
    }

    @Test("Haiku 4.5 is $1/$5, older Haiku tiers preserved")
    func haikuPricing() {
        #expect(ClaudePricing.price(for: "claude-haiku-4-5").inputPerMillion == 1)
        #expect(ClaudePricing.price(for: "claude-haiku-4-5").outputPerMillion == 5)
        #expect(ClaudePricing.price(for: "claude-3-5-haiku-20241022").inputPerMillion == 0.80)
        #expect(ClaudePricing.price(for: "claude-3-haiku-20240307").inputPerMillion == 0.25)
    }

    @Test("Fable 5 is $10/$50")
    func fablePricing() {
        let price = ClaudePricing.price(for: "claude-fable-5")
        #expect(price.inputPerMillion == 10)
        #expect(price.outputPerMillion == 50)
    }

    @Test("Context-window suffix [1m] is stripped")
    func contextSuffixNormalization() {
        let price = ClaudePricing.price(for: "claude-opus-4-7[1m]")
        #expect(price.inputPerMillion == 5)
        #expect(price.outputPerMillion == 25)
    }

    @Test("Unknown dated id falls back to its alias")
    func datedIDFallback() {
        let price = ClaudePricing.price(for: "claude-opus-4-7-20990101")
        #expect(price.inputPerMillion == 5)
    }

    @Test("Cache write tiers: 5m at 1.25x, 1h at 2x input")
    func cacheWriteTiers() {
        let price = ClaudePricing.price(for: "claude-sonnet-4-6")
        #expect(price.cacheWrite5mPerMillion == 3 * 1.25)
        #expect(price.cacheWrite1hPerMillion == 3 * 2.0)
        #expect(price.cacheReadPerMillion == 3 * 0.1)

        let cost = ClaudePricing.cost(
            model: "claude-sonnet-4-6",
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 1_000_000,
            cacheWrite5mTokens: 1_000_000,
            cacheWrite1hTokens: 1_000_000
        )
        #expect(abs(cost - (3 + 0.3 + 3.75 + 6)) < 0.0001)
    }
}

// MARK: - Transcript parsing

@Suite("TranscriptIngestor Tests")
struct TranscriptIngestorTests {
    private func makeLine(
        model: String = "claude-opus-4-7",
        timestamp: String = "2026-06-10T07:33:01.712Z",
        messageID: String? = "msg_1",
        requestID: String? = "req_1",
        input: Int = 10,
        output: Int = 20,
        cacheRead: Int = 100,
        cacheCreation: Int = 50,
        cacheDetail: String? = nil
    ) -> String {
        var usage = #""input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreation)"#
        if let cacheDetail {
            usage += #","cache_creation":\#(cacheDetail)"#
        }
        var line = #"{"type":"assistant","timestamp":"\#(timestamp)","cwd":"/Users/test/project""#
        if let requestID {
            line += #","requestId":"\#(requestID)""#
        }
        line += #","message":{"role":"assistant","model":"\#(model)""#
        if let messageID {
            line += #","id":"\#(messageID)""#
        }
        line += #","usage":{\#(usage)}}}"#
        return line
    }

    private func writeTempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-test-\(UUID().uuidString).jsonl")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    @Test("Parses assistant usage lines")
    func parsesUsage() throws {
        let content = [
            #"{"type":"user","timestamp":"2026-06-10T07:32:00.000Z","cwd":"/Users/test/project","message":{"role":"user"}}"#,
            self.makeLine(),
            "",
        ].joined(separator: "\n")
        let url = try writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try TranscriptIngestor.parse(fileURL: url, from: 0)
        #expect(result.entries.count == 1)
        #expect(result.cwd == "/Users/test/project")

        let entry = try #require(result.entries.first)
        #expect(entry.model == "claude-opus-4-7")
        #expect(entry.inputTokens == 10)
        #expect(entry.outputTokens == 20)
        #expect(entry.cacheReadTokens == 100)
        #expect(entry.cacheWrite5mTokens == 50)
        #expect(entry.cacheWrite1hTokens == 0)
        #expect(entry.dedupKey == "msg_1:req_1")

        // 2026-06-10T07 UTC
        let expectedHour = Int64(TranscriptIngestor.daysFromCivil(year: 2026, month: 6, day: 10)) * 86400 + 7 * 3600
        #expect(entry.hourStart == expectedHour)
    }

    @Test("Incremental parse resumes from offset and carries partial lines")
    func incrementalParse() throws {
        let line1 = self.makeLine(messageID: "m1", requestID: "r1")
        let url = try writeTempFile(line1 + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try TranscriptIngestor.parse(fileURL: url, from: 0)
        #expect(first.entries.count == 1)
        #expect(first.newOffset == Int64(line1.utf8.count + 1))

        // Append a complete line plus a partial (unterminated) line.
        let line2 = self.makeLine(messageID: "m2", requestID: "r2")
        let partial = String(self.makeLine(messageID: "m3", requestID: "r3").prefix(40))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: (line2 + "\n" + partial).data(using: .utf8)!)
        try handle.close()

        let second = try TranscriptIngestor.parse(fileURL: url, from: first.newOffset)
        #expect(second.entries.count == 1)
        #expect(second.entries.first?.dedupKey == "m2:r2")
        // Offset stops after line2's newline; the partial line is not consumed.
        #expect(second.newOffset == first.newOffset + Int64(line2.utf8.count + 1))

        // Complete the partial line: it gets picked up next round.
        let rest = String(self.makeLine(messageID: "m3", requestID: "r3").dropFirst(40))
        let handle2 = try FileHandle(forWritingTo: url)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: (rest + "\n").data(using: .utf8)!)
        try handle2.close()

        let third = try TranscriptIngestor.parse(fileURL: url, from: second.newOffset)
        #expect(third.entries.count == 1)
        #expect(third.entries.first?.dedupKey == "m3:r3")
    }

    @Test("Cache creation TTL detail splits 5m vs 1h")
    func cacheDetailSplit() throws {
        let line = self.makeLine(
            cacheCreation: 300,
            cacheDetail: #"{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}"#
        )
        let url = try writeTempFile(line + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try TranscriptIngestor.parse(fileURL: url, from: 0)
        let entry = try #require(result.entries.first)
        #expect(entry.cacheWrite5mTokens == 100)
        #expect(entry.cacheWrite1hTokens == 200)
    }

    @Test("Synthetic model and zero-usage lines are skipped")
    func skipsSyntheticAndEmpty() throws {
        let content = [
            self.makeLine(model: "<synthetic>"),
            self.makeLine(input: 0, output: 0, cacheRead: 0, cacheCreation: 0),
        ].joined(separator: "\n") + "\n"
        let url = try writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try TranscriptIngestor.parse(fileURL: url, from: 0)
        #expect(result.entries.isEmpty)
    }

    @Test("Model normalization strips context suffix")
    func modelNormalization() {
        #expect(TranscriptIngestor.normalizeModel("claude-opus-4-7[1m]") == "claude-opus-4-7")
        #expect(TranscriptIngestor.normalizeModel("Claude-Sonnet-4-6") == "claude-sonnet-4-6")
    }

    @Test("daysFromCivil matches known epochs")
    func daysFromCivil() {
        #expect(TranscriptIngestor.daysFromCivil(year: 1970, month: 1, day: 1) == 0)
        #expect(TranscriptIngestor.daysFromCivil(year: 2026, month: 1, day: 1) == 20454)
        // Leap-year boundary
        #expect(
            TranscriptIngestor.daysFromCivil(year: 2024, month: 3, day: 1)
                - TranscriptIngestor.daysFromCivil(year: 2024, month: 2, day: 28) == 2
        )
    }
}

// MARK: - Ledger store

@Suite("LedgerStore Tests")
struct LedgerStoreTests {
    private func makeStore() throws -> LedgerStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-store-\(UUID().uuidString).sqlite")
        return try LedgerStore(url: url)
    }

    private func entry(
        key: String?,
        hour: Int64 = 1_780_000_000 - (1_780_000_000 % 3600),
        model: String = "claude-opus-4-7",
        input: Int = 10,
        output: Int = 20
    ) -> ParsedUsageEntry {
        ParsedUsageEntry(
            dedupKey: key,
            hourStart: hour,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: 0,
            cacheWrite5mTokens: 0,
            cacheWrite1hTokens: 0
        )
    }

    @Test("Dedup is global across files")
    func globalDedup() throws {
        let store = try makeStore()

        let accepted1 = try store.commit(
            path: "/a.jsonl", source: "code", project: "/p",
            entries: [entry(key: "m1:r1"), entry(key: "m1:r1")],
            size: 100, mtime: 1, offset: 100
        )
        #expect(accepted1 == 1)

        // Same usage replayed in a second file (resumed session) is ignored.
        let accepted2 = try store.commit(
            path: "/b.jsonl", source: "code", project: "/p",
            entries: [entry(key: "m1:r1"), entry(key: "m2:r2")],
            size: 100, mtime: 1, offset: 100
        )
        #expect(accepted2 == 1)

        let rows = try store.hourRows(since: 0)
        let totalInput = rows.reduce(0) { $0 + $1.inputTokens }
        #expect(totalInput == 20) // two unique entries
    }

    @Test("Entries without dedup keys are always counted")
    func noKeyAlwaysCounted() throws {
        let store = try makeStore()
        let accepted = try store.commit(
            path: "/a.jsonl", source: "code", project: "",
            entries: [entry(key: nil), entry(key: nil)],
            size: 10, mtime: 1, offset: 10
        )
        #expect(accepted == 2)
    }

    @Test("File reset removes its aggregates and dedup ownership")
    func fileReset() throws {
        let store = try makeStore()
        try store.commit(
            path: "/a.jsonl", source: "code", project: "",
            entries: [entry(key: "m1:r1")],
            size: 10, mtime: 1, offset: 10
        )
        try store.resetFile(path: "/a.jsonl")
        #expect(try store.hourRows(since: 0).isEmpty)

        // After reset the same key can be ingested again (file rewritten).
        let accepted = try store.commit(
            path: "/a.jsonl", source: "code", project: "",
            entries: [entry(key: "m1:r1")],
            size: 10, mtime: 2, offset: 10
        )
        #expect(accepted == 1)
    }

    @Test("Purge removes records for deleted files")
    func purgeMissing() throws {
        let store = try makeStore()
        try store.commit(
            path: "/gone.jsonl", source: "code", project: "",
            entries: [entry(key: "m1:r1")],
            size: 10, mtime: 1, offset: 10
        )
        try store.purgeMissingFiles(existingPaths: [])
        #expect(try store.hourRows(since: 0).isEmpty)
        #expect(try store.allCursors().isEmpty)
    }
}

// MARK: - Blocks

@Suite("LedgerBlock Tests")
struct LedgerBlockTests {
    private func totals(_ tokens: Int) -> TokenTotals {
        TokenTotals(inputTokens: tokens, entryCount: 1, costUSD: 0.1)
    }

    @Test("Consecutive hours form one 5h block; gaps start new blocks")
    func blockGrouping() {
        let base: Int64 = 1_780_000_000 - (1_780_000_000 % 3600)
        var buckets: [Int64: (TokenTotals, [String: TokenTotals])] = [:]
        // Activity at hour 0, 1, 2 -> one block.
        buckets[base] = (totals(100), [:])
        buckets[base + 3600] = (totals(100), [:])
        buckets[base + 7200] = (totals(100), [:])
        // Gap of 6 hours -> new block.
        buckets[base + 9 * 3600] = (totals(50), [:])

        let blocks = TokenLedger.computeBlocks(hourBuckets: buckets)
        #expect(blocks.count == 2)
        #expect(blocks[0].totals.inputTokens == 300)
        #expect(blocks[0].start == Date(timeIntervalSince1970: TimeInterval(base)))
        #expect(blocks[0].end == Date(timeIntervalSince1970: TimeInterval(base + 5 * 3600)))
        #expect(blocks[1].totals.inputTokens == 50)
    }

    @Test("Activity past the 5h boundary starts a new block")
    func blockBoundary() {
        let base: Int64 = 1_780_000_000 - (1_780_000_000 % 3600)
        var buckets: [Int64: (TokenTotals, [String: TokenTotals])] = [:]
        buckets[base] = (totals(100), [:])
        buckets[base + 5 * 3600] = (totals(100), [:]) // exactly at boundary
        let blocks = TokenLedger.computeBlocks(hourBuckets: buckets)
        #expect(blocks.count == 2)
    }

    @Test("Block activity and burn rate")
    func blockBurnRate() {
        let start = Date(timeIntervalSinceNow: -3600) // started 1h ago
        let hourStart = Int64(start.timeIntervalSince1970 / 3600) * 3600
        let blocks = TokenLedger.computeBlocks(hourBuckets: [hourStart: (totals(60000), [:])])
        let block = blocks[0]
        #expect(block.isActive(at: Date()))
        let rate = block.burnRate(at: block.start.addingTimeInterval(3600))
        #expect(abs(rate - 1000) < 1) // 60k tokens over 60 minutes
    }
}

// MARK: - Desktop catalog

@Suite("DesktopSessionCatalog Tests")
struct DesktopSessionCatalogTests {
    @Test("Extracts cliSessionId from session metadata")
    func extractID() {
        let json = #"{"sessionId":"local_abc","cliSessionId":"9719DD88-1138-4483-8876-7df0e8b73b2e","cwd":"/Users/x"}"#
        let id = DesktopSessionCatalog.extractCLISessionID(from: json.data(using: .utf8)!)
        #expect(id == "9719DD88-1138-4483-8876-7df0e8b73b2e")
    }

    @Test("Returns nil when cliSessionId is absent")
    func missingID() {
        let json = #"{"sessionId":"local_abc"}"#
        #expect(DesktopSessionCatalog.extractCLISessionID(from: json.data(using: .utf8)!) == nil)
    }

    @Test("Scans a metadata directory tree")
    func scansDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-test-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("acct/workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meta = #"{"cliSessionId":"AAAA1111-2222-3333-4444-555566667777"}"#
        try meta.data(using: .utf8)!.write(to: nested.appendingPathComponent("local_test.json"))
        // Non-matching file is ignored.
        try meta.data(using: .utf8)!.write(to: nested.appendingPathComponent("other.json"))

        let ids = DesktopSessionCatalog.desktopSessionIDs(inRoot: root)
        #expect(ids == ["aaaa1111-2222-3333-4444-555566667777"])
    }
}
