import Testing
@testable import ControlTowerCore

@Suite("ProviderRegistry Tests")
struct ProviderRegistryTests {
    @Test("All providers have descriptors")
    func allProvidersHaveDescriptors() {
        for provider in ProviderID.allCases {
            let descriptor = ProviderRegistry.descriptor(for: provider)
            #expect(descriptor.id == provider)
            #expect(!descriptor.metadata.displayName.isEmpty)
        }
    }

    @Test("All descriptors have valid metadata")
    func allDescriptorsHaveValidMetadata() {
        let allDescriptors = ProviderRegistry.all
        #expect(allDescriptors.count == ProviderID.allCases.count)

        for descriptor in allDescriptors {
            #expect(!descriptor.metadata.displayName.isEmpty)
            #expect(!descriptor.metadata.sessionLabel.isEmpty)
            #expect(!descriptor.metadata.quotaLabel.isEmpty)
            #expect(descriptor.metadata.defaultRefreshInterval > 0)
        }
    }

    @Test("CLI name map contains all providers")
    func cliNameMapComplete() {
        let cliNameMap = ProviderRegistry.cliNameMap

        // Each provider should have at least its primary CLI name
        for provider in ProviderID.allCases {
            #expect(cliNameMap[provider.cliName] == provider)
        }
    }

    @Test("Provider lookup by CLI name works")
    func providerLookupByCLIName() {
        #expect(ProviderRegistry.provider(forCLIName: "claude") == .claude)
        #expect(ProviderRegistry.provider(forCLIName: "codex") == .codex)
        #expect(ProviderRegistry.provider(forCLIName: "cursor") == .cursor)
        #expect(ProviderRegistry.provider(forCLIName: "gemini") == .gemini)
        #expect(ProviderRegistry.provider(forCLIName: "copilot") == .copilot)
        #expect(ProviderRegistry.provider(forCLIName: "antigravity") == .antigravity)

        // Case insensitive
        #expect(ProviderRegistry.provider(forCLIName: "CLAUDE") == .claude)
        #expect(ProviderRegistry.provider(forCLIName: "Claude") == .claude)

        // Unknown returns nil
        #expect(ProviderRegistry.provider(forCLIName: "unknown") == nil)
    }

    @Test("Provider aliases work")
    func providerAliasesWork() {
        // Copilot has "github" alias
        #expect(ProviderRegistry.provider(forCLIName: "github") == .copilot)

        // Antigravity has "windsurf" and "codeium" aliases
        #expect(ProviderRegistry.provider(forCLIName: "windsurf") == .antigravity)
        #expect(ProviderRegistry.provider(forCLIName: "codeium") == .antigravity)
    }

    @Test("Claude descriptor has correct metadata")
    func claudeDescriptor() {
        let descriptor = ProviderRegistry.descriptor(for: .claude)
        #expect(descriptor.metadata.displayName == "Claude")
        #expect(descriptor.metadata.supportsTertiary == true)
        #expect(descriptor.metadata.supportsMultiAccount == true)
        #expect(descriptor.cliConfig.binaryName == "claude")
    }

    @Test("Antigravity descriptor has correct metadata")
    func antigravityDescriptor() {
        let descriptor = ProviderRegistry.descriptor(for: .antigravity)
        #expect(descriptor.metadata.displayName == "Antigravity")
        #expect(descriptor.metadata.supportsTertiary == true)
        #expect(descriptor.metadata.tertiaryLabel == "Gemini Flash")
        #expect(descriptor.cliConfig.aliases.contains("windsurf"))
        #expect(descriptor.cliConfig.aliases.contains("codeium"))
    }
}
