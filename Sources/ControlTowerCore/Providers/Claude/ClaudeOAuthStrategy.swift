import Foundation
#if os(macOS)
import Security
#endif

/// Fetch Claude usage via OAuth API using Claude CLI's stored credentials.
/// This is more reliable than PTY scraping as it uses direct API calls.
public struct ClaudeOAuthStrategy: ProviderFetchStrategy, Sendable {
    public let id = "claude-oauth"
    public let kind = ProviderFetchKind.oauth

    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private static let betaHeader = "oauth-2025-04-20"
    private static let credentialsPath = ".claude/.credentials.json"
    private static let keychainService = "Claude Code-credentials"

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Check if we can get OAuth credentials
        return (try? Self.loadCredentials()) != nil
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let credentials = try Self.loadCredentials()

        // Check if expired
        if credentials.isExpired {
            throw ProviderFetchError.authenticationRequired(.claude)
        }

        // Fetch usage from API
        let usage = try await Self.fetchUsage(accessToken: credentials.accessToken)

        // Build snapshot
        let snapshot = Self.buildSnapshot(usage: usage)
        return makeResult(usage: snapshot, sourceLabel: "oauth")
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        // Fall back to CLI/Web on any error
        return true
    }

    // MARK: - Credential Loading

    private struct OAuthCredentials {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return true }
            return Date() >= expiresAt
        }
    }

    private static func loadCredentials() throws -> OAuthCredentials {
        // Try credentials file first
        if let creds = try? loadFromFile() {
            return creds
        }

        // Try keychain
        #if os(macOS)
        if let creds = try? loadFromKeychain() {
            return creds
        }
        #endif

        throw ProviderFetchError.authenticationRequired(.claude)
    }

    private static func loadFromFile() throws -> OAuthCredentials {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(credentialsPath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderFetchError.authenticationRequired(.claude)
        }

        let data = try Data(contentsOf: url)
        return try parseCredentials(data)
    }

    #if os(macOS)
    private static func loadFromKeychain() throws -> OAuthCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data else {
            throw ProviderFetchError.authenticationRequired(.claude)
        }

        return try parseCredentials(data)
    }
    #endif

    private static func parseCredentials(_ data: Data) throws -> OAuthCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty else {
            throw ProviderFetchError.parseError("Invalid credentials format")
        }

        let refreshToken = oauth["refreshToken"] as? String
        let expiresAt: Date? = {
            if let millis = oauth["expiresAt"] as? Double {
                return Date(timeIntervalSince1970: millis / 1000.0)
            }
            return nil
        }()

        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    // MARK: - API Calls

    private static func fetchUsage(accessToken: String) async throws -> OAuthUsageResponse {
        guard let url = URL(string: usageURL) else {
            throw ProviderFetchError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("ControlTower", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.networkError("Invalid response")
        }

        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
        case 401:
            throw ProviderFetchError.invalidCredentials(.claude)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderFetchError.networkError("HTTP \(http.statusCode): \(body.prefix(200))")
        }
    }

    // MARK: - Response Parsing

    private static func buildSnapshot(usage: OAuthUsageResponse) -> UsageSnapshot {
        // Parse 5-hour session window
        // Note: API returns utilization as percentage (0-100), not decimal
        let primary = usage.fiveHour.map { window in
            RateWindow(
                usedPercent: window.utilization ?? 0,
                windowMinutes: 5 * 60,
                resetsAt: parseISO8601Date(window.resetsAt),
                label: "Session"
            )
        }

        // Parse 7-day all models window
        let secondary = usage.sevenDay.map { window in
            RateWindow(
                usedPercent: window.utilization ?? 0,
                windowMinutes: 7 * 24 * 60,
                resetsAt: parseISO8601Date(window.resetsAt),
                label: "Weekly"
            )
        }

        // Parse model-specific window (Sonnet or Opus)
        let modelWindow = usage.sevenDaySonnet ?? usage.sevenDayOpus
        let modelLabel = usage.sevenDaySonnet != nil ? "Sonnet" : "Opus"
        let tertiary = modelWindow.map { window in
            RateWindow(
                usedPercent: window.utilization ?? 0,
                windowMinutes: 7 * 24 * 60,
                resetsAt: parseISO8601Date(window.resetsAt),
                label: modelLabel
            )
        }

        // Parse extra usage/cost
        var cost: ProviderCostInfo?
        if let extra = usage.extraUsage, extra.isEnabled == true {
            let usedCents = extra.usedCredits ?? 0
            let limitCents = extra.monthlyLimit ?? 0
            cost = ProviderCostInfo(
                monthlyCostUSD: usedCents / 100.0,
                remainingCredits: (limitCents - usedCents) / 100.0,
                totalCredits: limitCents / 100.0,
                currencyCode: extra.currency ?? "USD",
                period: "Monthly"
            )
        }

        return UsageSnapshot(
            providerID: .claude,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            cost: cost,
            updatedAt: Date()
        )
    }

    private static func parseISO8601Date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Response Models

private struct OAuthUsageResponse: Decodable {
    let fiveHour: OAuthUsageWindow?
    let sevenDay: OAuthUsageWindow?
    let sevenDayOAuthApps: OAuthUsageWindow?
    let sevenDayOpus: OAuthUsageWindow?
    let sevenDaySonnet: OAuthUsageWindow?
    let iguanaNecktie: OAuthUsageWindow?
    let extraUsage: OAuthExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case iguanaNecktie = "iguana_necktie"
        case extraUsage = "extra_usage"
    }
}

private struct OAuthUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct OAuthExtraUsage: Decodable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}
