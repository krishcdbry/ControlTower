import Foundation

/// Complete descriptor for a provider, serving as the single source of truth.
public struct ProviderDescriptor: Sendable {
    /// Unique provider identifier.
    public let id: ProviderID

    /// Display metadata (labels, URLs, capabilities).
    public let metadata: ProviderMetadata

    /// Visual branding (colors, icons).
    public let branding: ProviderBranding

    /// Supported authentication methods.
    public let authMethods: [AuthMethodConfig]

    /// Fetch strategy pipeline.
    public let fetchPlan: ProviderFetchPlan

    /// Cost tracking configuration.
    public let costConfig: ProviderCostConfig

    /// CLI configuration.
    public let cliConfig: ProviderCLIConfig

    public init(
        id: ProviderID,
        metadata: ProviderMetadata,
        branding: ProviderBranding,
        authMethods: [AuthMethodConfig],
        fetchPlan: ProviderFetchPlan,
        costConfig: ProviderCostConfig = .init(),
        cliConfig: ProviderCLIConfig = .init()
    ) {
        self.id = id
        self.metadata = metadata
        self.branding = branding
        self.authMethods = authMethods
        self.fetchPlan = fetchPlan
        self.costConfig = costConfig
        self.cliConfig = cliConfig
    }

    /// Executes the fetch pipeline and returns a result.
    public func fetch(context: ProviderFetchContext) async -> ProviderFetchOutcome {
        await self.fetchPlan.fetch(context: context, provider: self.id)
    }
}

/// Configuration for a specific authentication method.
public struct AuthMethodConfig: Sendable {
    public let method: AuthMethod
    public let oauth: OAuthConfig?
    public let apiKey: APIKeyConfig?
    public let cookie: CookieConfig?
    public let cliCommand: String?

    public init(
        method: AuthMethod,
        oauth: OAuthConfig? = nil,
        apiKey: APIKeyConfig? = nil,
        cookie: CookieConfig? = nil,
        cliCommand: String? = nil
    ) {
        self.method = method
        self.oauth = oauth
        self.apiKey = apiKey
        self.cookie = cookie
        self.cliCommand = cliCommand
    }

    public static func oauth(_ config: OAuthConfig) -> AuthMethodConfig {
        AuthMethodConfig(method: .oauth, oauth: config)
    }

    public static func apiKey(_ config: APIKeyConfig) -> AuthMethodConfig {
        AuthMethodConfig(method: .apiKey, apiKey: config)
    }

    public static func cookies(_ config: CookieConfig) -> AuthMethodConfig {
        AuthMethodConfig(method: .cookies, cookie: config)
    }

    public static func cli(command: String? = nil) -> AuthMethodConfig {
        AuthMethodConfig(method: .cli, cliCommand: command)
    }
}

/// Cost tracking configuration for a provider.
public struct ProviderCostConfig: Sendable {
    /// Whether this provider supports token cost tracking.
    public let supportsTokenCost: Bool

    /// Message to show when cost data is unavailable.
    public let noDataMessage: String

    /// Cost per 1K input tokens, if known.
    public let inputTokenCostPer1K: Double?

    /// Cost per 1K output tokens, if known.
    public let outputTokenCostPer1K: Double?

    public init(
        supportsTokenCost: Bool = false,
        noDataMessage: String = "Cost tracking not available",
        inputTokenCostPer1K: Double? = nil,
        outputTokenCostPer1K: Double? = nil
    ) {
        self.supportsTokenCost = supportsTokenCost
        self.noDataMessage = noDataMessage
        self.inputTokenCostPer1K = inputTokenCostPer1K
        self.outputTokenCostPer1K = outputTokenCostPer1K
    }
}

/// CLI configuration for a provider.
public struct ProviderCLIConfig: Sendable {
    /// CLI binary name (e.g., "claude", "codex").
    public let binaryName: String?

    /// Aliases for the CLI name.
    public let aliases: [String]

    /// Command to check version.
    public let versionCommand: String?

    /// Command to get usage.
    public let usageCommand: String?

    public init(
        binaryName: String? = nil,
        aliases: [String] = [],
        versionCommand: String? = nil,
        usageCommand: String? = nil
    ) {
        self.binaryName = binaryName
        self.aliases = aliases
        self.versionCommand = versionCommand
        self.usageCommand = usageCommand
    }
}
