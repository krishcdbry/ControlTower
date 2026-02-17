import Foundation

/// Fetch Codex usage via OAuth credentials from ~/.codex/auth.json.
public struct CodexCLIStrategy: ProviderFetchStrategy, Sendable {
    public let id = "codex-cli"
    public let kind = ProviderFetchKind.cli

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Check if auth.json exists with valid tokens
        do {
            _ = try loadCredentials()
            return true
        } catch {
            return false
        }
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let credentials = try loadCredentials()
        let response = try await fetchUsage(credentials: credentials)
        return try parseResponse(response, credentials: credentials)
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case ProviderFetchError.authenticationRequired = error { return false }
        if case ProviderFetchError.invalidCredentials = error { return false }
        return true
    }

    // MARK: - Credentials

    private struct Credentials: Sendable {
        let accessToken: String
        let refreshToken: String
        let accountId: String?
        let lastRefresh: Date?
    }

    private func loadCredentials() throws -> Credentials {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let authPath: URL
        if let codexHome, !codexHome.isEmpty {
            authPath = URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        } else {
            authPath = home.appendingPathComponent(".codex/auth.json")
        }

        guard FileManager.default.fileExists(atPath: authPath.path) else {
            throw ProviderFetchError.authenticationRequired(.codex)
        }

        let data = try Data(contentsOf: authPath)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.authenticationRequired(.codex)
        }

        // Check for legacy API key first
        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Credentials(accessToken: apiKey, refreshToken: "", accountId: nil, lastRefresh: nil)
        }

        // Parse OAuth tokens
        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            throw ProviderFetchError.authenticationRequired(.codex)
        }

        let refreshToken = tokens["refresh_token"] as? String ?? ""
        let accountId = tokens["account_id"] as? String
        let lastRefresh = parseLastRefresh(json["last_refresh"])

        return Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountId: accountId,
            lastRefresh: lastRefresh
        )
    }

    private func parseLastRefresh(_ raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    // MARK: - Fetching

    private func fetchUsage(credentials: Credentials) async throws -> UsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ControlTower", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.parseError("Invalid response")
        }

        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        case 401, 403:
            throw ProviderFetchError.invalidCredentials(.codex)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderFetchError.parseError("HTTP \(http.statusCode): \(body)")
        }
    }

    // MARK: - Parsing

    private func parseResponse(_ response: UsageResponse, credentials: Credentials) throws -> ProviderFetchResult {
        var primary: RateWindow?
        var secondary: RateWindow?

        if let rateLimit = response.rateLimit {
            if let pw = rateLimit.primaryWindow {
                primary = RateWindow(
                    usedPercent: Double(pw.usedPercent),
                    windowMinutes: pw.limitWindowSeconds / 60,
                    resetsAt: Date(timeIntervalSince1970: TimeInterval(pw.resetAt)),
                    label: "Session"
                )
            }
            if let sw = rateLimit.secondaryWindow {
                secondary = RateWindow(
                    usedPercent: Double(sw.usedPercent),
                    windowMinutes: sw.limitWindowSeconds / 60,
                    resetsAt: Date(timeIntervalSince1970: TimeInterval(sw.resetAt)),
                    label: "Weekly"
                )
            }
        }

        // If no rate limits, check credits
        var credits: ProviderCostInfo?
        if let creditInfo = response.credits {
            if creditInfo.unlimited {
                // Unlimited plan - show 0% used
                if primary == nil {
                    primary = RateWindow(usedPercent: 0, label: "Unlimited")
                }
            } else if let balance = creditInfo.balance {
                credits = ProviderCostInfo(dailyCostUSD: nil, monthlyCostUSD: nil)
                if primary == nil {
                    // Credits-based plan - we don't know the limit
                    primary = RateWindow(usedPercent: 0, label: "Credits: $\(String(format: "%.2f", balance))")
                }
            }
        }

        // Default if no data
        if primary == nil {
            primary = RateWindow(usedPercent: 0, label: "Unknown")
        }

        let planName = response.planType?.rawValue.capitalized ?? "Unknown"

        let snapshot = UsageSnapshot(
            providerID: .codex,
            primary: primary,
            secondary: secondary,
            updatedAt: Date(),
            identity: ProviderIdentity(plan: planName, authMethod: "oauth")
        )

        return makeResult(usage: snapshot, sourceLabel: "oauth", credits: credits)
    }
}

// MARK: - Response Types

private struct UsageResponse: Decodable {
    let planType: PlanType?
    let rateLimit: RateLimitDetails?
    let credits: CreditDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
}

private enum PlanType: Sendable, Decodable {
    case guest
    case free
    case go
    case plus
    case pro
    case freeWorkspace
    case team
    case business
    case education
    case quorum
    case k12
    case enterprise
    case edu
    case unknown(String)

    var rawValue: String {
        switch self {
        case .guest: "guest"
        case .free: "free"
        case .go: "go"
        case .plus: "plus"
        case .pro: "pro"
        case .freeWorkspace: "free_workspace"
        case .team: "team"
        case .business: "business"
        case .education: "education"
        case .quorum: "quorum"
        case .k12: "k12"
        case .enterprise: "enterprise"
        case .edu: "edu"
        case let .unknown(value): value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "guest": self = .guest
        case "free": self = .free
        case "go": self = .go
        case "plus": self = .plus
        case "pro": self = .pro
        case "free_workspace": self = .freeWorkspace
        case "team": self = .team
        case "business": self = .business
        case "education": self = .education
        case "quorum": self = .quorum
        case "k12": self = .k12
        case "enterprise": self = .enterprise
        case "edu": self = .edu
        default:
            self = .unknown(value)
        }
    }
}

private struct RateLimitDetails: Decodable {
    let primaryWindow: WindowSnapshot?
    let secondaryWindow: WindowSnapshot?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct WindowSnapshot: Decodable {
    let usedPercent: Int
    let resetAt: Int
    let limitWindowSeconds: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }
}

private struct CreditDetails: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
        self.unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
        if let balance = try? container.decode(Double.self, forKey: .balance) {
            self.balance = balance
        } else if let balance = try? container.decode(String.self, forKey: .balance),
                  let value = Double(balance) {
            self.balance = value
        } else {
            self.balance = nil
        }
    }
}
