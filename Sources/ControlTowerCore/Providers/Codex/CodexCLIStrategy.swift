import Foundation

/// Reads the ChatGPT login shared by Codex Desktop and the CLI.
public struct CodexCLIStrategy: ProviderFetchStrategy, Sendable {
    public let id = "codex-cli"
    public let kind = ProviderFetchKind.cli

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        (try? loadCredentials(environment: context.environment)) != nil
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let credentials = try loadCredentials(environment: context.environment)
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ControlTower", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.parseError("Invalid usage response")
        }
        switch http.statusCode {
        case 200...299:
            return try parseResponse(data)
        case 401, 403:
            throw ProviderFetchError.invalidCredentials(.codex)
        case 429:
            throw ProviderFetchError.rateLimited(.codex, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        default:
            throw ProviderFetchError.parseError("Usage request failed (HTTP \(http.statusCode))")
        }
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case ProviderFetchError.authenticationRequired = error { return false }
        if case ProviderFetchError.invalidCredentials = error { return false }
        return true
    }

    private struct Credentials: Sendable {
        let accessToken: String
        let accountID: String?
    }

    private func loadCredentials(environment: [String: String]) throws -> Credentials {
        let authPath = CodexPaths.home(environment: environment).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["auth_mode"] as? String != "apikey",
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // API keys do not grant access to ChatGPT subscription quotas.
            // Local token accounting remains available without this login.
            throw ProviderFetchError.authenticationRequired(.codex)
        }
        return Credentials(accessToken: accessToken, accountID: tokens["account_id"] as? String)
    }

    func parseResponse(_ data: Data, now: Date = Date()) throws -> ProviderFetchResult {
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        let primary = response.rateLimit?.primaryWindow?.window(now: now)
        let secondary = response.rateLimit?.secondaryWindow?.window(now: now)
        var metadata = ["scope": "Account usage shared across Codex apps"]
        if response.credits?.unlimited == true { metadata["credits"] = "Unlimited" }
        if let balance = response.credits?.balance { metadata["creditBalance"] = String(balance) }

        // Missing windows are unavailable data, never evidence of 0% usage.
        let snapshot = UsageSnapshot(
            providerID: .codex,
            primary: primary,
            secondary: secondary,
            updatedAt: now,
            identity: ProviderIdentity(plan: response.planType?.rawValue.capitalized, authMethod: "oauth"),
            metadata: metadata
        )
        return makeResult(usage: snapshot, sourceLabel: "oauth")
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
    let usedPercent: Double
    let resetAt: Int?
    let resetAfterSeconds: Int?
    let limitWindowSeconds: Int

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case resetAfterSeconds = "reset_after_seconds"
        case limitWindowSeconds = "limit_window_seconds"
    }

    func window(now: Date) -> RateWindow {
        let minutes = max(1, limitWindowSeconds / 60)
        let label: String
        switch minutes {
        case 300: label = "Session"
        case 1440: label = "Daily"
        case 10080: label = "Weekly"
        default: label = minutes % 60 == 0 ? "\(minutes / 60) Hours" : "\(minutes) Minutes"
        }
        let reset = resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? resetAfterSeconds.map { now.addingTimeInterval(TimeInterval($0)) }
        return RateWindow(usedPercent: usedPercent, windowMinutes: minutes, resetsAt: reset, label: label)
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
