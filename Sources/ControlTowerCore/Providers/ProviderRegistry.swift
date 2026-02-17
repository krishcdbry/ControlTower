import Foundation

/// Central registry for all provider descriptors.
public enum ProviderRegistry {
    /// All registered provider descriptors by ID.
    private static let descriptorsByID: [ProviderID: ProviderDescriptor] = {
        var descriptors: [ProviderID: ProviderDescriptor] = [:]
        for provider in ProviderID.allCases {
            descriptors[provider] = makeDescriptor(for: provider)
        }
        return descriptors
    }()

    /// Get the descriptor for a provider.
    public static func descriptor(for id: ProviderID) -> ProviderDescriptor {
        guard let descriptor = descriptorsByID[id] else {
            fatalError("Missing descriptor for provider: \(id)")
        }
        return descriptor
    }

    /// All provider descriptors.
    public static var all: [ProviderDescriptor] {
        ProviderID.allCases.map { descriptor(for: $0) }
    }

    /// All provider metadata.
    public static var metadata: [ProviderID: ProviderMetadata] {
        var result: [ProviderID: ProviderMetadata] = [:]
        for provider in ProviderID.allCases {
            result[provider] = descriptor(for: provider).metadata
        }
        return result
    }

    /// Map from CLI names to provider IDs.
    public static var cliNameMap: [String: ProviderID] {
        var result: [String: ProviderID] = [:]
        for provider in ProviderID.allCases {
            let descriptor = self.descriptor(for: provider)
            result[provider.cliName] = provider
            for alias in descriptor.cliConfig.aliases {
                result[alias] = provider
            }
        }
        return result
    }

    /// Look up a provider by CLI name.
    public static func provider(forCLIName name: String) -> ProviderID? {
        self.cliNameMap[name.lowercased()]
    }

    // MARK: - Provider Descriptor Factory

    private static func makeDescriptor(for provider: ProviderID) -> ProviderDescriptor {
        switch provider {
        case .claude:
            return makeClaudeDescriptor()
        case .codex:
            return makeCodexDescriptor()
        case .cursor:
            return makeCursorDescriptor()
        case .gemini:
            return makeGeminiDescriptor()
        case .copilot:
            return makeCopilotDescriptor()
        case .antigravity:
            return makeAntigravityDescriptor()
        }
    }

    // MARK: - Claude

    private static func makeClaudeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: ProviderID.claude,
            metadata: ProviderMetadata(
                id: ProviderID.claude,
                displayName: "Claude",
                sessionLabel: "Session",
                quotaLabel: "Weekly",
                tertiaryLabel: "Opus",
                supportsTertiary: true,
                supportsCredits: false,
                supportsMultiAccount: true,
                dashboardURL: URL(string: "https://console.anthropic.com/settings/billing"),
                statusPageURL: URL(string: "https://status.anthropic.com"),
                defaultRefreshInterval: 300,
                description: "Anthropic Claude Code usage"
            ),
            branding: ProviderBranding(
                iconStyle: IconStyle.claude,
                iconResourceName: "ProviderIcon-claude",
                color: ProviderColor.claude
            ),
            authMethods: [
                AuthMethodConfig.cli(command: "claude"),
            ],
            fetchPlan: ProviderFetchPipeline { _ in
                [ClaudeCLIStrategy()]
            },
            costConfig: ProviderCostConfig(
                supportsTokenCost: true,
                inputTokenCostPer1K: 0.003,
                outputTokenCostPer1K: 0.015
            ),
            cliConfig: ProviderCLIConfig(
                binaryName: "claude",
                usageCommand: "/usage"
            )
        )
    }

    // MARK: - Codex

    private static func makeCodexDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: ProviderID.codex,
            metadata: ProviderMetadata(
                id: ProviderID.codex,
                displayName: "Codex",
                sessionLabel: "Session",
                quotaLabel: "Weekly",
                supportsCredits: true,
                supportsMultiAccount: true,
                dashboardURL: URL(string: "https://platform.openai.com/usage"),
                statusPageURL: URL(string: "https://status.openai.com"),
                defaultRefreshInterval: 300,
                description: "OpenAI Codex CLI usage"
            ),
            branding: ProviderBranding(
                iconStyle: IconStyle.codex,
                iconResourceName: "ProviderIcon-codex",
                color: ProviderColor.codex
            ),
            authMethods: [
                AuthMethodConfig.cli(command: "codex"),
            ],
            fetchPlan: ProviderFetchPipeline { _ in
                [CodexCLIStrategy()]
            },
            costConfig: ProviderCostConfig(
                supportsTokenCost: true,
                inputTokenCostPer1K: 0.01,
                outputTokenCostPer1K: 0.03
            ),
            cliConfig: ProviderCLIConfig(
                binaryName: "codex",
                usageCommand: "/usage"
            )
        )
    }

    // MARK: - Cursor

    private static func makeCursorDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: ProviderID.cursor,
            metadata: ProviderMetadata(
                id: ProviderID.cursor,
                displayName: "Cursor",
                sessionLabel: "Plan",
                quotaLabel: "Credits",
                supportsCredits: true,
                supportsMultiAccount: false,
                dashboardURL: URL(string: "https://www.cursor.com/settings"),
                statusPageURL: nil,
                defaultRefreshInterval: 300,
                description: "Cursor IDE usage"
            ),
            branding: ProviderBranding(
                iconStyle: IconStyle.cursor,
                iconResourceName: "ProviderIcon-cursor",
                color: ProviderColor.cursor
            ),
            authMethods: [
                AuthMethodConfig.cookies(CookieConfig(
                    domains: ["cursor.com", "www.cursor.com"],
                    requiredCookies: ["WorkosCursorSessionToken"]
                )),
            ],
            fetchPlan: ProviderFetchPipeline { _ in
                [CursorWebStrategy()]
            },
            cliConfig: ProviderCLIConfig()
        )
    }

    // MARK: - Gemini

    private static func makeGeminiDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: ProviderID.gemini,
            metadata: ProviderMetadata(
                id: ProviderID.gemini,
                displayName: "Gemini",
                sessionLabel: "RPM",
                quotaLabel: "Daily",
                supportsCredits: false,
                supportsMultiAccount: true,
                dashboardURL: URL(string: "https://aistudio.google.com/app/apikey"),
                statusPageURL: URL(string: "https://status.cloud.google.com"),
                defaultRefreshInterval: 300,
                description: "Google Gemini CLI usage"
            ),
            branding: ProviderBranding(
                iconStyle: IconStyle.gemini,
                iconResourceName: "ProviderIcon-gemini",
                color: ProviderColor.gemini
            ),
            authMethods: [
                AuthMethodConfig.apiKey(APIKeyConfig(
                    environmentVariable: "GEMINI_API_KEY",
                    keychainKey: "Gemini-apikey",
                    placeholder: "Enter Gemini API key..."
                )),
                AuthMethodConfig.cli(command: "gemini"),
            ],
            fetchPlan: ProviderFetchPipeline { _ in
                [GeminiCLIStrategy()]
            },
            cliConfig: ProviderCLIConfig(
                binaryName: "gemini",
                usageCommand: "--usage"
            )
        )
    }

    // MARK: - Copilot

    private static func makeCopilotDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: ProviderID.copilot,
            metadata: ProviderMetadata(
                id: ProviderID.copilot,
                displayName: "Copilot",
                sessionLabel: "Status",
                quotaLabel: "Plan",
                supportsCredits: false,
                supportsMultiAccount: true,
                dashboardURL: URL(string: "https://github.com/settings/copilot"),
                statusPageURL: URL(string: "https://www.githubstatus.com"),
                defaultRefreshInterval: 300,
                description: "GitHub Copilot usage"
            ),
            branding: ProviderBranding(
                iconStyle: IconStyle.copilot,
                iconResourceName: "ProviderIcon-copilot",
                color: ProviderColor.copilot
            ),
            authMethods: [
                AuthMethodConfig.cli(command: "gh auth login"),
            ],
            fetchPlan: ProviderFetchPipeline { _ in
                [CopilotCLIStrategy(), CopilotAPIStrategy()]
            },
            cliConfig: ProviderCLIConfig(
                binaryName: "gh",
                aliases: ["github"]
            )
        )
    }

    // MARK: - Antigravity

    private static func makeAntigravityDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: ProviderID.antigravity,
            metadata: ProviderMetadata(
                id: ProviderID.antigravity,
                displayName: "Antigravity",
                sessionLabel: "Claude",
                quotaLabel: "Gemini Pro",
                tertiaryLabel: "Gemini Flash",
                supportsTertiary: true,
                supportsCredits: false,
                supportsMultiAccount: false,
                dashboardURL: nil,
                statusPageURL: URL(string: "https://www.google.com/appsstatus/dashboard"),
                defaultRefreshInterval: 300,
                description: "Google Antigravity usage"
            ),
            branding: ProviderBranding(
                iconStyle: IconStyle.antigravity,
                iconResourceName: "ProviderIcon-antigravity",
                color: ProviderColor(red: 96.0 / 255.0, green: 186.0 / 255.0, blue: 126.0 / 255.0)
            ),
            authMethods: [
                AuthMethodConfig.cli(command: "Launch Windsurf/Codeium"),
            ],
            fetchPlan: ProviderFetchPipeline { _ in
                [AntigravityCLIStrategy()]
            },
            cliConfig: ProviderCLIConfig(
                binaryName: "antigravity",
                aliases: ["windsurf", "codeium"]
            )
        )
    }
}
