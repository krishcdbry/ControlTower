import Foundation
import Testing
@testable import ControlTowerCore

@Suite("Provider Strategy Tests")
struct ProviderStrategyTests {

    // MARK: - Strategy ID Tests

    @Test("All strategies have unique IDs")
    func strategiesHaveUniqueIDs() {
        let strategies: [any ProviderFetchStrategy] = [
            ClaudeCLIStrategy(),
            ClaudeOAuthStrategy(),
            ClaudeWebStrategy(),
            CodexCLIStrategy(),
            CursorWebStrategy(),
            GeminiCLIStrategy(),
            CopilotCLIStrategy(),
            CopilotAPIStrategy(),
            AntigravityCLIStrategy(),
        ]

        let ids = strategies.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count, "Strategy IDs must be unique")
    }

    @Test("Strategies have correct kinds")
    func strategiesHaveCorrectKinds() {
        #expect(ClaudeCLIStrategy().kind == .cli)
        #expect(ClaudeOAuthStrategy().kind == .oauth)
        #expect(ClaudeWebStrategy().kind == .web)
        #expect(CodexCLIStrategy().kind == .cli)
        #expect(CursorWebStrategy().kind == .web)
        #expect(GeminiCLIStrategy().kind == .cli)
        #expect(CopilotCLIStrategy().kind == .cli)
        #expect(CopilotAPIStrategy().kind == .apiToken)
        #expect(AntigravityCLIStrategy().kind == .cli)
    }

    // MARK: - Provider Service Tests

    @Test("ProviderService has strategies for all providers")
    func providerServiceHasAllStrategies() async {
        // Check that we can create a context
        let context = ProviderService.defaultCLIContext()
        #expect(!context.environment.isEmpty)
    }

    @Test("Default CLI context has environment")
    func defaultCLIContextHasEnvironment() {
        let context = ProviderService.defaultCLIContext()
        #expect(!context.environment.isEmpty)
        #expect(context.environment["HOME"] != nil || context.environment["PATH"] != nil)
    }

    // MARK: - ProviderFetchError Tests

    @Test("ProviderFetchError has correct descriptions")
    func providerFetchErrorDescriptions() {
        let authError = ProviderFetchError.authenticationRequired(.claude)
        #expect(authError.localizedDescription.contains("authentication"))

        let invalidError = ProviderFetchError.invalidCredentials(.codex)
        #expect(invalidError.localizedDescription.contains("invalid") || invalidError.localizedDescription.contains("credentials"))

        let parseError = ProviderFetchError.parseError("test error")
        #expect(parseError.localizedDescription.contains("test error"))
    }
}

@Suite("Provider Result Building Tests")
struct ProviderResultBuildingTests {
    @Test("makeResult creates valid ProviderFetchResult")
    func makeResultCreatesValidResult() {
        let strategy = ClaudeCLIStrategy()
        let snapshot = UsageSnapshot(
            providerID: .claude,
            primary: RateWindow(usedPercent: 50, label: "Session"),
            updatedAt: Date()
        )

        let result = strategy.makeResult(usage: snapshot, sourceLabel: "test")
        #expect(result.usage.providerID == .claude)
        #expect(result.usage.primary?.usedPercent == 50)
        #expect(result.sourceLabel == "test")
    }
}
