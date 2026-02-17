import Testing
@testable import ControlTowerCore

@Suite("ProviderID Tests")
struct ProviderIDTests {
    @Test("All providers have valid IDs")
    func allProvidersHaveValidIDs() {
        let providers = ProviderID.allCases
        #expect(providers.count == 6)
        #expect(providers.contains(.claude))
        #expect(providers.contains(.codex))
        #expect(providers.contains(.cursor))
        #expect(providers.contains(.gemini))
        #expect(providers.contains(.copilot))
        #expect(providers.contains(.antigravity))
    }

    @Test("Provider display names are set")
    func providerDisplayNames() {
        #expect(ProviderID.claude.displayName == "Claude")
        #expect(ProviderID.codex.displayName == "Codex")
        #expect(ProviderID.cursor.displayName == "Cursor")
        #expect(ProviderID.gemini.displayName == "Gemini")
        #expect(ProviderID.copilot.displayName == "Copilot")
        #expect(ProviderID.antigravity.displayName == "Antigravity")
    }

    @Test("Provider CLI names are lowercase")
    func providerCLINames() {
        for provider in ProviderID.allCases {
            #expect(provider.cliName == provider.cliName.lowercased())
        }
    }

    @Test("Provider raw values are unique")
    func providerRawValuesUnique() {
        let rawValues = ProviderID.allCases.map(\.rawValue)
        let uniqueValues = Set(rawValues)
        #expect(rawValues.count == uniqueValues.count)
    }
}
