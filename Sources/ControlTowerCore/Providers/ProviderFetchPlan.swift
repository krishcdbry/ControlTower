import Foundation

/// The type of fetch strategy.
public enum ProviderFetchKind: String, Sendable, Codable {
    case cli
    case web
    case oauth
    case apiToken
    case localProbe
}

/// Source mode selection for fetching.
public enum ProviderSourceMode: String, Sendable, Codable, CaseIterable {
    case auto    // Try strategies in order
    case cli     // Force CLI only
    case web     // Force web/cookies only
    case oauth   // Force OAuth only
    case api     // Force API token only
}

/// Protocol for a fetch strategy that can retrieve usage data.
public protocol ProviderFetchStrategy: Sendable {
    /// Unique identifier for this strategy.
    var id: String { get }

    /// The kind of fetch this strategy performs.
    var kind: ProviderFetchKind { get }

    /// Check if this strategy is available (credentials exist, etc.).
    func isAvailable(_ context: ProviderFetchContext) async -> Bool

    /// Perform the fetch and return results.
    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult

    /// Whether to try the next strategy on this error.
    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool
}

extension ProviderFetchStrategy {
    /// Helper to create a fetch result.
    public func makeResult(
        usage: UsageSnapshot,
        sourceLabel: String,
        credits: ProviderCostInfo? = nil
    ) -> ProviderFetchResult {
        ProviderFetchResult(
            usage: usage,
            credits: credits,
            sourceLabel: sourceLabel,
            strategyID: self.id,
            strategyKind: self.kind
        )
    }
}

/// Context provided to fetch strategies.
public struct ProviderFetchContext: Sendable {
    /// Runtime environment (app or CLI).
    public let runtime: FetchRuntime

    /// Selected source mode.
    public let sourceMode: ProviderSourceMode

    /// Environment variables.
    public let environment: [String: String]

    /// Settings snapshot.
    public let settings: ProviderSettingsSnapshot?

    /// Account to fetch for (if multi-account).
    public let account: ProviderAccount?

    /// Browser detection info.
    public let browserDetection: BrowserDetection?

    public init(
        runtime: FetchRuntime,
        sourceMode: ProviderSourceMode = .auto,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        settings: ProviderSettingsSnapshot? = nil,
        account: ProviderAccount? = nil,
        browserDetection: BrowserDetection? = nil
    ) {
        self.runtime = runtime
        self.sourceMode = sourceMode
        self.environment = environment
        self.settings = settings
        self.account = account
        self.browserDetection = browserDetection
    }
}

/// Runtime environment for the fetch.
public enum FetchRuntime: Sendable {
    case app
    case cli
}

/// Settings snapshot passed to fetch strategies.
public struct ProviderSettingsSnapshot: Sendable {
    public let cookieSource: CookieSourceMode
    public let apiToken: String?
    public let customSettings: [String: String]

    public init(
        cookieSource: CookieSourceMode = .auto,
        apiToken: String? = nil,
        customSettings: [String: String] = [:]
    ) {
        self.cookieSource = cookieSource
        self.apiToken = apiToken
        self.customSettings = customSettings
    }
}

/// Cookie source mode.
public enum CookieSourceMode: String, Sendable, Codable {
    case auto
    case manual
    case off
}

/// Browser detection information.
public struct BrowserDetection: Sendable {
    public let availableBrowsers: [Browser]
    public let defaultBrowser: Browser?

    public init(availableBrowsers: [Browser] = [], defaultBrowser: Browser? = nil) {
        self.availableBrowsers = availableBrowsers
        self.defaultBrowser = defaultBrowser
    }
}

/// Result of a successful fetch.
public struct ProviderFetchResult: Sendable {
    /// The usage snapshot.
    public let usage: UsageSnapshot

    /// Optional credits/cost info.
    public let credits: ProviderCostInfo?

    /// Human-readable source label (e.g., "oauth", "cli").
    public let sourceLabel: String

    /// ID of the strategy that succeeded.
    public let strategyID: String

    /// Kind of the strategy.
    public let strategyKind: ProviderFetchKind

    public init(
        usage: UsageSnapshot,
        credits: ProviderCostInfo? = nil,
        sourceLabel: String,
        strategyID: String,
        strategyKind: ProviderFetchKind
    ) {
        self.usage = usage
        self.credits = credits
        self.sourceLabel = sourceLabel
        self.strategyID = strategyID
        self.strategyKind = strategyKind
    }
}

/// Record of a fetch attempt.
public struct ProviderFetchAttempt: Sendable {
    public let strategyID: String
    public let wasAvailable: Bool
    public let error: Error?

    public init(strategyID: String, wasAvailable: Bool, error: Error? = nil) {
        self.strategyID = strategyID
        self.wasAvailable = wasAvailable
        self.error = error
    }
}

/// Outcome of a fetch operation (success or failure with attempts).
public struct ProviderFetchOutcome: Sendable {
    public let result: Result<ProviderFetchResult, Error>
    public let attempts: [ProviderFetchAttempt]

    public init(result: Result<ProviderFetchResult, Error>, attempts: [ProviderFetchAttempt]) {
        self.result = result
        self.attempts = attempts
    }

    public var isSuccess: Bool {
        if case .success = self.result { return true }
        return false
    }

    public var usage: UsageSnapshot? {
        if case let .success(result) = self.result { return result.usage }
        return nil
    }

    public var error: Error? {
        if case let .failure(error) = self.result { return error }
        return nil
    }
}

/// Errors that can occur during fetching.
public enum ProviderFetchError: LocalizedError, Sendable {
    case noAvailableStrategy(ProviderID)
    case authenticationRequired(ProviderID, message: String? = nil)
    case invalidCredentials(ProviderID)
    case networkError(String)
    case parseError(String)
    case timeout(ProviderID)
    case rateLimited(ProviderID, retryAfter: TimeInterval?)
    case commandFailed(String)
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case let .noAvailableStrategy(provider):
            "No available fetch strategy for \(provider.displayName)"
        case let .authenticationRequired(provider, message):
            message ?? "\(provider.displayName) requires authentication"
        case let .invalidCredentials(provider):
            "Invalid credentials for \(provider.displayName)"
        case let .networkError(message):
            "Network error: \(message)"
        case let .parseError(message):
            "Parse error: \(message)"
        case let .timeout(provider):
            "\(provider.displayName) request timed out"
        case let .rateLimited(provider, retryAfter):
            if let retry = retryAfter {
                "\(provider.displayName) rate limited, retry after \(Int(retry))s"
            } else {
                "\(provider.displayName) rate limited"
            }
        case let .commandFailed(message):
            "Command failed: \(message)"
        case let .apiError(message):
            "API error: \(message)"
        }
    }
}

/// Type alias for backward compatibility.
public typealias ProviderFetchPlan = ProviderFetchPipeline

/// Pipeline that executes fetch strategies in order.
public struct ProviderFetchPipeline: Sendable {
    /// Function that resolves available strategies for the context.
    public let resolveStrategies: @Sendable (ProviderFetchContext) async -> [any ProviderFetchStrategy]

    public init(resolveStrategies: @escaping @Sendable (ProviderFetchContext) async -> [any ProviderFetchStrategy]) {
        self.resolveStrategies = resolveStrategies
    }

    /// Execute the pipeline and return the outcome.
    public func fetch(context: ProviderFetchContext, provider: ProviderID) async -> ProviderFetchOutcome {
        let strategies = await self.resolveStrategies(context)
        var attempts: [ProviderFetchAttempt] = []

        // Filter strategies by source mode
        let filteredStrategies = strategies.filter { strategy in
            switch context.sourceMode {
            case .auto:
                return true
            case .cli:
                return strategy.kind == .cli
            case .web:
                return strategy.kind == .web
            case .oauth:
                return strategy.kind == .oauth
            case .api:
                return strategy.kind == .apiToken
            }
        }

        for strategy in filteredStrategies {
            // Check availability
            let isAvailable = await strategy.isAvailable(context)
            if !isAvailable {
                attempts.append(ProviderFetchAttempt(
                    strategyID: strategy.id,
                    wasAvailable: false
                ))
                continue
            }

            // Attempt fetch
            do {
                let result = try await strategy.fetch(context)
                return ProviderFetchOutcome(result: .success(result), attempts: attempts)
            } catch {
                attempts.append(ProviderFetchAttempt(
                    strategyID: strategy.id,
                    wasAvailable: true,
                    error: error
                ))

                // Check if we should fall back to next strategy
                if strategy.shouldFallback(on: error, context: context) {
                    continue
                }

                return ProviderFetchOutcome(result: .failure(error), attempts: attempts)
            }
        }

        // No strategy succeeded
        return ProviderFetchOutcome(
            result: .failure(ProviderFetchError.noAvailableStrategy(provider)),
            attempts: attempts
        )
    }
}
