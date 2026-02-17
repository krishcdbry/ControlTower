import Foundation

/// Fetch Gemini usage via OAuth credentials or API key.
public struct GeminiCLIStrategy: ProviderFetchStrategy, Sendable {
    public let id = "gemini-cli"
    public let kind = ProviderFetchKind.cli

    private static let quotaEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private static let loadCodeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let credentialsPath = ".gemini/oauth_creds.json"
    private static let settingsPath = ".gemini/settings.json"
    private static let accountsPath = ".gemini/google_accounts.json"

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Check for API key in environment
        if let key = context.environment["GEMINI_API_KEY"], !key.isEmpty {
            return true
        }
        if let key = context.environment["GOOGLE_API_KEY"], !key.isEmpty {
            return true
        }

        // Check if OAuth credentials exist
        let credsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Self.credentialsPath)

        guard FileManager.default.fileExists(atPath: credsPath.path) else {
            return false
        }

        // Verify we have an access token
        guard let data = try? Data(contentsOf: credsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            return false
        }

        return true
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Try API key first
        if let apiKey = resolveAPIKey(context: context) {
            return try await fetchWithAPIKey(apiKey)
        }

        // Fall back to OAuth
        return try await fetchWithOAuth()
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case ProviderFetchError.authenticationRequired = error { return false }
        if case ProviderFetchError.invalidCredentials = error { return false }
        return true
    }

    // MARK: - API Key Auth

    private func resolveAPIKey(context: ProviderFetchContext) -> String? {
        if let key = context.environment["GEMINI_API_KEY"], !key.isEmpty {
            return key
        }
        if let key = context.environment["GOOGLE_API_KEY"], !key.isEmpty {
            return key
        }
        return nil
    }

    private func fetchWithAPIKey(_ apiKey: String) async throws -> ProviderFetchResult {
        // For API key auth, we can only verify the key works
        // Gemini API doesn't expose usage for API keys, only rate limit headers
        let url = URL(string: "https://generativelanguage.googleapis.com/v1/models?key=\(apiKey)")!

        let (_, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.parseError("Invalid response")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderFetchError.invalidCredentials(.gemini)
        }

        guard http.statusCode == 200 else {
            throw ProviderFetchError.parseError("HTTP \(http.statusCode)")
        }

        // Parse rate limit headers if available
        let rateLimit = http.value(forHTTPHeaderField: "X-RateLimit-Limit")
        let rateRemaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")

        var usedPercent: Double = 0
        if let limit = rateLimit.flatMap(Double.init),
           let remaining = rateRemaining.flatMap(Double.init),
           limit > 0 {
            usedPercent = ((limit - remaining) / limit) * 100
        }

        let snapshot = UsageSnapshot(
            providerID: .gemini,
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 1, // Per minute
                resetsAt: Date().addingTimeInterval(60),
                label: "RPM"
            ),
            updatedAt: Date(),
            identity: ProviderIdentity(plan: "API Key", authMethod: "api-key")
        )

        return makeResult(usage: snapshot, sourceLabel: "api")
    }

    // MARK: - OAuth Auth

    private struct Credentials {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let expiryDate: Date?
    }

    private func fetchWithOAuth() async throws -> ProviderFetchResult {
        let credentials = try loadCredentials()

        // Check auth type - only support OAuth
        let authType = loadAuthType()
        if authType == "api-key" {
            throw ProviderFetchError.parseError("API key auth configured. Set GEMINI_API_KEY environment variable.")
        }

        // Check if token is expired
        let accessToken = credentials.accessToken
        if let expiry = credentials.expiryDate, expiry < Date() {
            throw ProviderFetchError.authenticationRequired(.gemini)
        }

        // First get project ID and tier from loadCodeAssist
        let codeAssistInfo = try await loadCodeAssist(accessToken: accessToken)

        // Fetch quota with project ID
        let quotas = try await fetchQuota(accessToken: accessToken, projectId: codeAssistInfo.projectId)
        let email = extractEmailFromToken(credentials.idToken)
        let accountEmail = loadAccountEmail() ?? email

        return buildResult(quotas: quotas, email: accountEmail, tier: codeAssistInfo.tier)
    }

    private func loadCredentials() throws -> Credentials {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let credsPath = home.appendingPathComponent(Self.credentialsPath)

        guard FileManager.default.fileExists(atPath: credsPath.path) else {
            throw ProviderFetchError.authenticationRequired(.gemini)
        }

        let data = try Data(contentsOf: credsPath)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw ProviderFetchError.authenticationRequired(.gemini)
        }

        let refreshToken = json["refresh_token"] as? String
        let idToken = json["id_token"] as? String

        var expiryDate: Date?
        if let expiryMs = json["expiry_date"] as? Double {
            expiryDate = Date(timeIntervalSince1970: expiryMs / 1000)
        }

        return Credentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiryDate: expiryDate
        )
    }

    private func loadAuthType() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsPath = home.appendingPathComponent(Self.settingsPath)

        guard let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = json["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let selectedType = auth["selectedType"] as? String else {
            return nil
        }

        return selectedType
    }

    private func loadAccountEmail() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let accountsPath = home.appendingPathComponent(Self.accountsPath)

        guard let data = try? Data(contentsOf: accountsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = json["active"] as? String else {
            return nil
        }

        return active
    }

    // MARK: - API Calls

    private struct CodeAssistInfo {
        let tier: String?
        let projectId: String?
    }

    private func loadCodeAssist(accessToken: String) async throws -> CodeAssistInfo {
        guard let url = URL(string: Self.loadCodeAssistEndpoint) else {
            throw ProviderFetchError.parseError("Invalid loadCodeAssist endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}".utf8)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.parseError("Invalid response")
        }

        if http.statusCode == 401 {
            throw ProviderFetchError.invalidCredentials(.gemini)
        }

        guard http.statusCode == 200 else {
            throw ProviderFetchError.parseError("HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.parseError("Invalid loadCodeAssist response")
        }

        // Extract project ID
        var projectId: String?
        if let project = json["cloudaicompanionProject"] as? String, !project.isEmpty {
            projectId = project
        }

        // Extract tier
        var tier: String?
        if let currentTier = json["currentTier"] as? [String: Any],
           let tierId = currentTier["id"] as? String {
            switch tierId {
            case "free-tier": tier = "Free"
            case "standard-tier": tier = "Standard"
            case "g1-pro-tier": tier = "Pro"
            case "legacy-tier": tier = "Legacy"
            default: tier = tierId
            }
        }

        return CodeAssistInfo(tier: tier, projectId: projectId)
    }

    private func fetchQuota(accessToken: String, projectId: String?) async throws -> [ModelQuota] {
        guard let url = URL(string: Self.quotaEndpoint) else {
            throw ProviderFetchError.parseError("Invalid quota endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Include project ID if available
        if let projectId {
            request.httpBody = Data("{\"project\":\"\(projectId)\"}".utf8)
        } else {
            request.httpBody = Data("{}".utf8)
        }
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ProviderFetchError.parseError("Invalid response")
        }

        if http.statusCode == 401 {
            throw ProviderFetchError.invalidCredentials(.gemini)
        }

        if http.statusCode == 403 {
            // 403 usually means subscription required - return empty quotas
            return []
        }

        guard http.statusCode == 200 else {
            throw ProviderFetchError.parseError("HTTP \(http.statusCode)")
        }

        return try parseQuotaResponse(data)
    }

    // MARK: - Parsing

    private struct ModelQuota {
        let modelId: String
        let percentLeft: Double
        let resetTime: Date?
    }

    private func parseQuotaResponse(_ data: Data) throws -> [ModelQuota] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = json["buckets"] as? [[String: Any]] else {
            return []
        }

        // Group by model, keep lowest fraction per model
        var modelQuotaMap: [String: (fraction: Double, resetTime: String?)] = [:]

        for bucket in buckets {
            guard let modelId = bucket["modelId"] as? String,
                  let fraction = bucket["remainingFraction"] as? Double else {
                continue
            }

            // Skip vertex models (duplicates)
            if modelId.hasSuffix("_vertex") { continue }

            let resetTime = bucket["resetTime"] as? String

            if let existing = modelQuotaMap[modelId] {
                if fraction < existing.fraction {
                    modelQuotaMap[modelId] = (fraction, resetTime)
                }
            } else {
                modelQuotaMap[modelId] = (fraction, resetTime)
            }
        }

        return modelQuotaMap.map { modelId, info in
            ModelQuota(
                modelId: modelId,
                percentLeft: info.fraction * 100,
                resetTime: parseResetTime(info.resetTime)
            )
        }.sorted { $0.modelId < $1.modelId }
    }

    private func parseResetTime(_ isoString: String?) -> Date? {
        guard let isoString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }

    private func extractEmailFromToken(_ idToken: String?) -> String? {
        guard let token = idToken else { return nil }

        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            return nil
        }

        return email
    }

    // MARK: - Result Building

    private func buildResult(quotas: [ModelQuota], email: String?, tier: String?) -> ProviderFetchResult {
        // Group quotas: Pro models as primary, Flash as secondary
        let proQuotas = quotas.filter { $0.modelId.lowercased().contains("pro") }
        let flashQuotas = quotas.filter { $0.modelId.lowercased().contains("flash") && !$0.modelId.lowercased().contains("lite") }

        let proMin = proQuotas.min(by: { $0.percentLeft < $1.percentLeft })
        let flashMin = flashQuotas.min(by: { $0.percentLeft < $1.percentLeft })

        let primary: RateWindow
        if let pro = proMin {
            primary = RateWindow(
                usedPercent: 100 - pro.percentLeft,
                windowMinutes: 1440, // Daily
                resetsAt: pro.resetTime,
                label: "Pro"
            )
        } else if let flash = flashMin {
            primary = RateWindow(
                usedPercent: 100 - flash.percentLeft,
                windowMinutes: 1440,
                resetsAt: flash.resetTime,
                label: "Flash"
            )
        } else {
            // No quota data - might be free tier or unlimited
            primary = RateWindow(usedPercent: 0, label: tier ?? "Connected")
        }

        var secondary: RateWindow?
        if proMin != nil, let flash = flashMin {
            secondary = RateWindow(
                usedPercent: 100 - flash.percentLeft,
                windowMinutes: 1440,
                resetsAt: flash.resetTime,
                label: "Flash"
            )
        }

        let snapshot = UsageSnapshot(
            providerID: .gemini,
            primary: primary,
            secondary: secondary,
            updatedAt: Date(),
            identity: ProviderIdentity(email: email, plan: tier, authMethod: "oauth")
        )

        return makeResult(usage: snapshot, sourceLabel: "oauth")
    }
}
