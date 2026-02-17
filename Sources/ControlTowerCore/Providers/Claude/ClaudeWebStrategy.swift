import Foundation

/// Fetch Claude usage via the claude.ai web API.
/// Endpoints:
/// - GET https://claude.ai/api/organizations → get org UUID
/// - GET https://claude.ai/api/organizations/{org_id}/usage → usage data
///
/// Note: This strategy requires browser session cookies which are encrypted by Chromium.
/// For now, it will check for a sessionKey but cookie decryption is not implemented.
/// Future: integrate SweetCookieKit when Swift 6.2+ is available.
public struct ClaudeWebStrategy: ProviderFetchStrategy, Sendable {
    public let id = "claude-web"
    public let kind = ProviderFetchKind.web

    private static let baseURL = "https://claude.ai/api"

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Check if we can get Claude session cookie
        // For now, this requires manual setup or environment variable
        return getSessionKeyFromEnv() != nil
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let sessionKey = getSessionKeyFromEnv() else {
            throw ProviderFetchError.authenticationRequired(.claude)
        }

        // Step 1: Get organization ID
        let orgId = try await fetchOrganizationId(sessionKey: sessionKey)

        // Step 2: Fetch usage data
        let usage = try await fetchUsage(orgId: orgId, sessionKey: sessionKey)

        // Step 3: Optionally fetch extra usage/overage limits
        let extraUsage = try? await fetchOverageLimit(orgId: orgId, sessionKey: sessionKey)

        // Build the snapshot
        let snapshot = buildSnapshot(usage: usage, extraUsage: extraUsage)
        return makeResult(usage: snapshot, sourceLabel: "web")
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        // Fall back on auth errors or network errors
        return true
    }

    // MARK: - Cookie Extraction

    /// Get session key from environment variable as a workaround
    /// Users can set CLAUDE_SESSION_KEY to their sessionKey cookie value
    private func getSessionKeyFromEnv() -> String? {
        if let key = ProcessInfo.processInfo.environment["CLAUDE_SESSION_KEY"] {
            if key.hasPrefix("sk-ant-") {
                return key
            }
        }
        return nil
    }

    // MARK: - API Calls

    private func fetchOrganizationId(sessionKey: String) async throws -> String {
        let url = URL(string: "\(Self.baseURL)/organizations")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderFetchError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw ProviderFetchError.invalidCredentials(.claude)
        default:
            throw ProviderFetchError.networkError("HTTP \(httpResponse.statusCode)")
        }

        // Parse organizations response - it's an array, get first org's UUID
        guard let orgs = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let firstOrg = orgs.first,
              let uuid = firstOrg["uuid"] as? String
        else {
            throw ProviderFetchError.parseError("Could not extract organization UUID")
        }

        return uuid
    }

    private func fetchUsage(orgId: String, sessionKey: String) async throws -> WebUsageResponse {
        let url = URL(string: "\(Self.baseURL)/organizations/\(orgId)/usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderFetchError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw ProviderFetchError.invalidCredentials(.claude)
        default:
            throw ProviderFetchError.networkError("HTTP \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(WebUsageResponse.self, from: data)
    }

    private func fetchOverageLimit(orgId: String, sessionKey: String) async throws -> OverageResponse {
        let url = URL(string: "\(Self.baseURL)/organizations/\(orgId)/overage_spend_limit")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderFetchError.networkError("Failed to fetch overage limit")
        }

        return try JSONDecoder().decode(OverageResponse.self, from: data)
    }

    // MARK: - Response Parsing

    private func buildSnapshot(usage: WebUsageResponse, extraUsage: OverageResponse?) -> UsageSnapshot {
        // Parse primary (5-hour session)
        let primary = usage.fiveHour.map { window in
            RateWindow(
                usedPercent: window.utilization ?? 0,
                windowMinutes: 5 * 60,
                resetsAt: parseISO8601Date(window.resetsAt),
                label: "Session"
            )
        }

        // Parse secondary (7-day all models)
        let secondary = usage.sevenDay.map { window in
            RateWindow(
                usedPercent: window.utilization ?? 0,
                windowMinutes: 7 * 24 * 60,
                resetsAt: parseISO8601Date(window.resetsAt),
                label: "Weekly"
            )
        }

        // Parse tertiary (model-specific - Sonnet or Opus)
        let modelWindow = usage.sevenDaySonnet ?? usage.sevenDayOpus
        let tertiary = modelWindow.map { window in
            RateWindow(
                usedPercent: window.utilization ?? 0,
                windowMinutes: 7 * 24 * 60,
                resetsAt: parseISO8601Date(window.resetsAt),
                label: usage.sevenDaySonnet != nil ? "Sonnet" : "Opus"
            )
        }

        // Parse extra usage cost
        var cost: ProviderCostInfo? = nil
        if let extra = extraUsage, extra.isEnabled == true {
            // Values are in cents, convert to dollars
            let usedDollars = (extra.usedCredits ?? 0) / 100.0
            let limitDollars = (extra.monthlyCreditLimit ?? 0) / 100.0
            cost = ProviderCostInfo(
                monthlyCostUSD: usedDollars,
                remainingCredits: limitDollars - usedDollars,
                totalCredits: limitDollars,
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

    private func parseISO8601Date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Response Models

private struct WebUsageResponse: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOAuthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let iguanaNecktie: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case iguanaNecktie = "iguana_necktie"
    }
}

private struct UsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct OverageResponse: Decodable {
    let isEnabled: Bool?
    let monthlyCreditLimit: Double?
    let usedCredits: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyCreditLimit = "monthly_credit_limit"
        case usedCredits = "used_credits"
        case currency
    }
}
