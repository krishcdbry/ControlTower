import Foundation
import GRDB
import Testing
@testable import ControlTowerCore

private struct CodexFixture {
    let root: URL
    let database: URL
    let environment: [String: String]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = root.appendingPathComponent("ledger.sqlite")
        environment = ["CODEX_HOME": "  \(root.path)\n"]
        for name in ["sessions", "archived_sessions"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, name: String = "sessions/original.jsonl") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func ledger() -> CodexLedger { CodexLedger(storeURL: database, environment: environment) }

    static func context(model: String = "gpt-6-astra") -> String {
        // Spaces are deliberate: JSON serialization need not be compact.
        #"{"type": "turn_context", "payload": {"model": "\#(model)", "cwd": "/fixture"}}"# + "\n"
    }

    static func record(id: String = "response-1", total: Int = 110, timestamp: String? = nil) -> String {
        let timestamp = timestamp ?? ISO8601DateFormatter().string(from: Date())
        return #"{"timestamp":"\#(timestamp)","type":"token_usage_record","payload":{"response_id":"\#(id)","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":110},"thread_token_usage":{"total_tokens":\#(total)}}}"# + "\n"
    }

    static func legacy(total: Int = 110, timestamp: String? = nil) -> String {
        let timestamp = timestamp ?? ISO8601DateFormatter().string(from: Date())
        return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":5}}}}"# + "\n"
    }
}

@Suite("Codex desktop ledger integration")
struct CodexIntegrationTests {
    @Test("Durable desktop records and mirrored notifications count once across scans")
    func desktopRecords() async throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        let record = CodexFixture.record()
        let url = try fixture.write(CodexFixture.context() + record)
        let ledger = fixture.ledger()
        let first = await ledger.snapshot(forceScan: true)
        #expect(first.days.reduce(0) { $0 + $1.totalTokens } == 110)
        #expect(first.days.first?.inputTokens == 20)
        #expect(first.days.first?.reasoningTokens == 5)
        #expect(first.days.first?.costUSD != nil)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((CodexFixture.legacy() + CodexFixture.record(id: "response-2", total: 220)).utf8))
        try handle.close()
        let second = await ledger.snapshot(forceScan: true)
        #expect(second.days.reduce(0) { $0 + $1.totalTokens } == 220)
        #expect(second.stats.entriesAdded == 1)
        let unchanged = await ledger.snapshot(forceScan: true)
        #expect(unchanged.stats.filesParsed == 0)
        let reopened = await fixture.ledger().snapshot(forceScan: true)
        #expect(reopened.days == unchanged.days)
        #expect(reopened.stats.filesParsed == 0)
    }

    @Test("Forks, archived moves, and deletion preserve exactly one copy of usage")
    func forkAndArchive() async throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        let content = CodexFixture.context() + CodexFixture.record()
        let original = try fixture.write(content)
        _ = try fixture.write(content + CodexFixture.record(id: "response-2", total: 220), name: "sessions/fork.jsonl")
        let ledger = fixture.ledger()
        let first = await ledger.snapshot(forceScan: true)
        #expect(first.days.reduce(0) { $0 + $1.totalTokens } == 220)
        let archived = fixture.root.appendingPathComponent("archived_sessions/original.jsonl")
        try FileManager.default.moveItem(at: original, to: archived)
        let moved = await ledger.snapshot(forceScan: true)
        #expect(moved.days == first.days)
        try FileManager.default.removeItem(at: archived)
        let removed = await ledger.snapshot(forceScan: true)
        #expect(removed.days == first.days)
    }

    @Test("Legacy fork history is deduplicated globally")
    func legacyFork() async throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        let content = CodexFixture.context() + CodexFixture.legacy()
        _ = try fixture.write(content)
        _ = try fixture.write(content, name: "archived_sessions/copy.jsonl")
        let result = await fixture.ledger().snapshot(forceScan: true)
        #expect(result.days.reduce(0) { $0 + $1.totalTokens } == 110)
    }

    @Test("Partial records wait for a newline and are counted after completion")
    func partialRecord() throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        let record = CodexFixture.record()
        let url = try fixture.write(CodexFixture.context() + String(record.dropLast(4)))
        let first = try CodexSessionIngestor.parse(fileURL: url, from: 0, lastTotalTokens: 0, model: "")
        #expect(first.entries.isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(record.suffix(4).utf8))
        try handle.close()
        let second = try CodexSessionIngestor.parse(fileURL: url, from: first.newOffset, lastTotalTokens: first.lastTotalTokens, model: first.model)
        #expect(second.entries.count == 1)
        #expect(second.model == "gpt-6-astra")
    }

    @Test("Unlisted models retain totals and disclose their estimated cost")
    func unknownPrice() async throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        _ = try fixture.write(CodexFixture.context(model: "new-unpriced-model") + CodexFixture.record())
        let result = await fixture.ledger().snapshot(forceScan: true)
        let cost = CodexCostScanner.adapt(result)
        #expect(cost.last30DaysTokens == 110)
        #expect(cost.last30DaysCostUSD == 0.000312)
        #expect(result.fallbackModels == ["new-unpriced-model"])
        #expect(result.fallbackTokens == 110)
        #expect(cost.dailyCosts.first?.costUSD == cost.last30DaysCostUSD)
    }

    @Test("App attribution survives incremental scans and day drill-down reads")
    func incrementalSource() async throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        let metadata = #"{"type":"session_meta","payload":{"source":"vscode","originator":"codex_work_desktop","cwd":"/fixture"}}"# + "\n"
        let url = try fixture.write(metadata + CodexFixture.context() + CodexFixture.record())
        let ledger = fixture.ledger()
        let first = await ledger.snapshot(forceScan: true)
        #expect(first.analytics.bySource[.codexDesktop]?.totalTokens == 110)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(CodexFixture.record(id: "new", total: 220).utf8))
        try handle.close()
        let second = await ledger.snapshot(forceScan: true)
        #expect(second.analytics.bySource[.codexDesktop]?.totalTokens == 220)
        let day = try #require(second.days.last?.date)
        let detail = await ledger.dayDetail(date: day)
        #expect(detail?.totals.totalTokens == 220)
        #expect(detail?.bySource[.codexDesktop]?.totalTokens == 220)
    }

    @Test("Resuming with reset counters includes the first new response")
    func counterReset() throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        let url = try fixture.write(CodexFixture.context() + CodexFixture.record(total: 1000) + CodexFixture.record(id: "resumed", total: 110))
        let parsed = try CodexSessionIngestor.parse(fileURL: url, from: 0, lastTotalTokens: 0, model: "")
        #expect(parsed.entries.count == 2)
        #expect(parsed.lastTotalTokens == 110)
    }

    @Test("Upgrading clears old Codex aggregates while preserving Claude history")
    func migration() throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        let store = try LedgerStore(url: fixture.database)
        try store.commit(path: "old-codex", source: "codex", project: "", entries: [], size: 100, mtime: 1, offset: 100)
        try store.commit(path: "old-claude", source: "claudeCode", project: "", entries: [], size: 200, mtime: 1, offset: 200)
        let queue = try DatabaseQueue(path: fixture.database.path)
        try queue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('ledger_v4_codex_records', 'ledger_v5_codex_sources')")
        }
        let upgraded = try LedgerStore(url: fixture.database)
        let cursors = try upgraded.allCursors()
        #expect(cursors["old-codex"] == nil)
        #expect(cursors["old-claude"]?.offset == 200)
    }

    @Test("Local midnight is preserved in India and numeric timezone offsets")
    func localMidnight() throws {
        var cache: [String: Int64] = [:]
        let bucket = try #require(CodexSessionIngestor.usageBucket(from: "2026-09-05T18:45:42.000Z", cache: &cache))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        #expect(TokenLedger.dayKey(for: Date(timeIntervalSince1970: TimeInterval(bucket)), calendar: calendar) == "2026-09-06")
        let offset = CodexSessionIngestor.usageBucket(from: "2026-09-06T00:15:42+05:30", cache: &cache)
        #expect(offset == bucket)
    }

    @Test("Custom home includes active and archived sessions and is watched before creation")
    func roots() {
        let environment = ["CODEX_HOME": " /tmp/unused-fixture \n"]
        #expect(CodexPaths.sessionRoots(environment: environment).map(\.lastPathComponent) == ["sessions", "archived_sessions"])
        #expect(CodexLedger.watchRoots(environment: environment).first?.path == "/tmp/unused-fixture")
    }
}

private final class CodexUsageStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization")
        let status = token == "Bearer expired" ? 401 : token == "Bearer limited" ? 429 : 200
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "fixture-account")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "42"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":12.5,"limit_window_seconds":604800,"reset_at":1800000000}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Codex account usage")
struct CodexUsageTests {
    @Test("Desktop credentials work without a CLI executable and respect custom home")
    func desktopCredentials() async throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        _ = try fixture.write(#"{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-token","account_id":"fixture-account"}}"#, name: "auth.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexUsageStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let strategy = CodexCLIStrategy(session: session)
        let context = ProviderFetchContext(runtime: .app, environment: fixture.environment)
        #expect(await strategy.isAvailable(context))
        let result = try await strategy.fetch(context)
        #expect(result.usage.primary?.label == "Weekly")
        #expect(result.usage.primary?.windowMinutes == 10080)
        #expect(result.usage.primary?.usedPercent == 12.5)
        #expect(result.usage.secondary == nil)
        #expect(result.usage.identity?.plan == "Prolite")
    }

    @Test("API keys are not sent to the subscription usage endpoint")
    func apiKey() async throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        _ = try fixture.write(#"{"auth_mode":"apikey","OPENAI_API_KEY":"fixture-api-key"}"#, name: "auth.json")
        #expect(await !CodexCLIStrategy().isAvailable(ProviderFetchContext(runtime: .app, environment: fixture.environment)))
    }

    @Test("Unavailable windows and credit balances do not manufacture zero percent quotas")
    func unavailable() throws {
        let result = try CodexCLIStrategy().parseResponse(Data(#"{"credits":{"balance":"500","has_credits":true,"unlimited":false}}"#.utf8))
        #expect(result.usage.primary == nil)
        #expect(!result.usage.hasUsageWindows)
        #expect(result.usage.secondary == nil)
        #expect(result.usage.metadata["creditBalance"] == "500.0")
    }

    @Test("Session and weekly windows preserve reset timing")
    func windows() throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let result = try CodexCLIStrategy().parseResponse(Data(#"{"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_after_seconds":60},"secondary_window":{"used_percent":85.25,"limit_window_seconds":604800}}}"#.utf8), now: now)
        #expect(result.usage.primary?.label == "Session")
        #expect(result.usage.primary?.resetsAt == now.addingTimeInterval(60))
        #expect(result.usage.secondary?.label == "Weekly")
        #expect(result.usage.secondary?.resetsAt == nil)
    }

    @Test("Expired login and throttling return actionable errors", arguments: ["expired", "limited"])
    func errors(token: String) async throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        _ = try fixture.write(#"{"tokens":{"access_token":"\#(token)","account_id":"fixture-account"}}"#, name: "auth.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexUsageStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await CodexCLIStrategy(session: session).fetch(ProviderFetchContext(runtime: .app, environment: fixture.environment))
            Issue.record("Expected a usage request error")
        } catch ProviderFetchError.invalidCredentials(.codex) {
            #expect(token == "expired")
        } catch ProviderFetchError.rateLimited(.codex, let retryAfter) {
            #expect(token == "limited")
            #expect(retryAfter == 42)
        }
    }
}
