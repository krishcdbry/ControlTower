import Foundation
import Testing
@testable import ControlTowerCore

// MARK: - Codex pricing

@Suite("CodexPricing Tests")
struct CodexPricingTests {
    @Test("Known model rates")
    func knownModels() {
        #expect(CodexPricing.price(for: "gpt-6-astra")?.inputPerMillion == 10)
        #expect(CodexPricing.price(for: "gpt-6-astra")?.outputPerMillion == 50)
        #expect(CodexPricing.price(for: "gpt-5.6-sol")?.inputPerMillion == 4)
        #expect(CodexPricing.price(for: "gpt-5.6-terra")?.outputPerMillion == 12)
        #expect(CodexPricing.price(for: "gpt-5.6-luna")?.inputPerMillion == 0.2)
        #expect(CodexPricing.price(for: "gpt-5.2")?.inputPerMillion == 1.75)
        #expect(CodexPricing.price(for: "gpt-5.4")?.inputPerMillion == 2.5)
        #expect(CodexPricing.price(for: "gpt-5.4")?.outputPerMillion == 15.0)
        #expect(CodexPricing.price(for: "gpt-5.3-codex")?.inputPerMillion == 1.75)
        #expect(CodexPricing.price(for: "gpt-5.1-codex-max")?.inputPerMillion == 1.25)
        #expect(CodexPricing.price(for: "gpt-5.1-codex-max")?.outputPerMillion == 10.0)
    }

    @Test("Cached input is 90% off")
    func cachedDiscount() {
        let price = CodexPricing.price(for: "gpt-5.1-codex")!
        #expect(abs(price.cachedInputPerMillion - 0.125) < 0.0001)
    }

    @Test("Unknown models have no guessed price")
    func familyFallback() {
        #expect(CodexPricing.price(for: "gpt-5.4-mini-preview") == nil)
        #expect(CodexPricing.price(for: "gpt-5.4-mini-2026-03-17")?.inputPerMillion == 0.75)
        #expect(CodexPricing.price(for: "gpt-5.3-codex-spark") == nil)
        #expect(CodexPricing.price(for: "something-new") == nil)
        #expect(CodexPricing.price(for: "codex-internal-unlisted") == nil)
    }

    @Test("Cost math: input excludes cached, output includes reasoning")
    func costMath() {
        let cost = CodexPricing.cost(
            model: "gpt-5.1-codex",
            inputTokens: 1_000_000,
            cachedInputTokens: 1_000_000,
            outputTokens: 1_000_000
        )
        #expect(abs(cost! - (1.25 + 0.125 + 10.0)) < 0.0001)
    }
}

// MARK: - Codex ingestor

@Suite("CodexSessionIngestor Tests")
struct CodexSessionIngestorTests {
    private func tokenLine(
        timestamp: String = "2026-06-10T07:33:01.712Z",
        totalInput: Int, totalCached: Int, totalOutput: Int, totalReasoning: Int,
        lastInput: Int, lastCached: Int, lastOutput: Int, lastReasoning: Int
    ) -> String {
        let total = totalInput + totalOutput
        let lastTotal = lastInput + lastOutput
        return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":\#(totalCached),"output_tokens":\#(totalOutput),"reasoning_output_tokens":\#(totalReasoning),"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(lastInput),"cached_input_tokens":\#(lastCached),"output_tokens":\#(lastOutput),"reasoning_output_tokens":\#(lastReasoning),"total_tokens":\#(lastTotal)},"model_context_window":258400},"rate_limits":{}}}"#
    }

    private func writeTempFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-test-\(UUID().uuidString).jsonl")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    @Test("Sums per-turn deltas, not cumulative totals")
    func sumsDeltas() throws {
        let content = [
            #"{"timestamp":"2026-06-10T07:30:00.000Z","type":"session_meta","payload":{"id":"x","cwd":"/Users/dev/project"}}"#,
            #"{"timestamp":"2026-06-10T07:30:01.000Z","type":"turn_context","payload":{"cwd":"/Users/dev/project","model":"gpt-5.1-codex-max"}}"#,
            // Turn 1: 1000 in (800 cached) / 50 out (20 reasoning)
            tokenLine(totalInput: 1000, totalCached: 800, totalOutput: 50, totalReasoning: 20,
                      lastInput: 1000, lastCached: 800, lastOutput: 50, lastReasoning: 20),
            // Heartbeat duplicate of the same cumulative state: must be skipped
            tokenLine(totalInput: 1000, totalCached: 800, totalOutput: 50, totalReasoning: 20,
                      lastInput: 1000, lastCached: 800, lastOutput: 50, lastReasoning: 20),
            // Turn 2: +2000 in (+1900 cached) / +100 out (+60 reasoning)
            tokenLine(totalInput: 3000, totalCached: 2700, totalOutput: 150, totalReasoning: 80,
                      lastInput: 2000, lastCached: 1900, lastOutput: 100, lastReasoning: 60),
            "",
        ].joined(separator: "\n")
        let url = try writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try CodexSessionIngestor.parse(fileURL: url, from: 0, lastTotalTokens: 0, model: "")
        #expect(result.entries.count == 2)
        #expect(result.cwd == "/Users/dev/project")
        #expect(result.model == "gpt-5.1-codex-max")
        #expect(result.lastTotalTokens == 3150)

        let totalNonCachedInput = result.entries.reduce(0) { $0 + $1.inputTokens }
        let totalCached = result.entries.reduce(0) { $0 + $1.cacheReadTokens }
        let totalOutput = result.entries.reduce(0) { $0 + $1.outputTokens }
        let totalReasoning = result.entries.reduce(0) { $0 + $1.cacheWrite5mTokens }
        #expect(totalNonCachedInput == 300) // (1000-800) + (2000-1900)
        #expect(totalCached == 2700)
        #expect(totalOutput == 150)
        #expect(totalReasoning == 80)
    }

    @Test("Incremental parse carries the cumulative baseline across scans")
    func incrementalBaseline() throws {
        let line1 = tokenLine(totalInput: 1000, totalCached: 0, totalOutput: 50, totalReasoning: 0,
                              lastInput: 1000, lastCached: 0, lastOutput: 50, lastReasoning: 0)
        let url = try writeTempFile(line1 + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try CodexSessionIngestor.parse(fileURL: url, from: 0, lastTotalTokens: 0, model: "")
        #expect(first.entries.count == 1)
        #expect(first.lastTotalTokens == 1050)

        // Append a duplicate heartbeat of the same state plus a real new turn.
        let dup = tokenLine(totalInput: 1000, totalCached: 0, totalOutput: 50, totalReasoning: 0,
                            lastInput: 1000, lastCached: 0, lastOutput: 50, lastReasoning: 0)
        let turn2 = tokenLine(totalInput: 1500, totalCached: 0, totalOutput: 80, totalReasoning: 0,
                              lastInput: 500, lastCached: 0, lastOutput: 30, lastReasoning: 0)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: (dup + "\n" + turn2 + "\n").data(using: .utf8)!)
        try handle.close()

        // Resume with the persisted offset + baseline: the duplicate is skipped.
        let second = try CodexSessionIngestor.parse(
            fileURL: url, from: first.newOffset,
            lastTotalTokens: first.lastTotalTokens, model: first.model
        )
        #expect(second.entries.count == 1)
        #expect(second.entries.first?.inputTokens == 500)
        #expect(second.entries.first?.outputTokens == 30)
        #expect(second.lastTotalTokens == 1580)
    }

    @Test("Model changes mid-session are tracked")
    func modelSwitch() throws {
        let content = [
            #"{"timestamp":"2026-06-10T07:30:01.000Z","type":"turn_context","payload":{"model":"gpt-5.1-codex"}}"#,
            tokenLine(totalInput: 100, totalCached: 0, totalOutput: 10, totalReasoning: 0,
                      lastInput: 100, lastCached: 0, lastOutput: 10, lastReasoning: 0),
            #"{"timestamp":"2026-06-10T07:40:01.000Z","type":"turn_context","payload":{"model":"gpt-5.4"}}"#,
            tokenLine(totalInput: 300, totalCached: 0, totalOutput: 30, totalReasoning: 0,
                      lastInput: 200, lastCached: 0, lastOutput: 20, lastReasoning: 0),
            "",
        ].joined(separator: "\n")
        let url = try writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try CodexSessionIngestor.parse(fileURL: url, from: 0, lastTotalTokens: 0, model: "")
        #expect(result.entries.count == 2)
        #expect(result.entries[0].model == "gpt-5.1-codex")
        #expect(result.entries[1].model == "gpt-5.4")
        #expect(result.model == "gpt-5.4")
    }

    @Test("Null info and non-advancing totals are skipped")
    func skipsNullAndStale() throws {
        let nullInfo = #"{"timestamp":"2026-06-10T07:30:02.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}"#
        let content = nullInfo + "\n"
        let url = try writeTempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try CodexSessionIngestor.parse(fileURL: url, from: 0, lastTotalTokens: 0, model: "")
        #expect(result.entries.isEmpty)
        #expect(result.lastTotalTokens == 0)
    }
}

// MARK: - Adapter

@Suite("CodexCostScanner Adapter Tests")
struct CodexCostScannerAdapterTests {
    @Test("Window totals roll up from days; reasoning not double-counted")
    func windowTotals() {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let now = Date()
        let todayKey = TokenLedger.dayKey(for: now, calendar: calendar)
        let tenDaysAgo = TokenLedger.dayKey(for: now.addingTimeInterval(-10 * 86400), calendar: calendar)

        let snapshot = CodexLedgerSnapshot(
            generatedAt: now,
            days: [
                CodexLedgerDay(date: tenDaysAgo, inputTokens: 100, cachedInputTokens: 900, outputTokens: 50, reasoningTokens: 30, costUSD: 1.0),
                CodexLedgerDay(date: todayKey, inputTokens: 200, cachedInputTokens: 800, outputTokens: 100, reasoningTokens: 60, costUSD: 2.0),
            ],
            stats: LedgerScanStats()
        )

        let cost = CodexCostScanner.adapt(snapshot, now: now)
        #expect(cost.todayTokens == 1100) // 200 + 800 + 100, reasoning excluded
        #expect(cost.todayCostUSD == 2.0)
        #expect(cost.last7DaysTokens == 1100)
        #expect(cost.last30DaysTokens == 2150)
        #expect(abs(cost.last30DaysCostUSD! - 3.0) < 0.0001)
        #expect(cost.dailyCosts.count == 2)
        #expect(cost.dailyCosts[1].reasoningTokens == 60)
    }
}
