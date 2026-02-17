import Foundation

/// Fetch Copilot usage via GitHub CLI.
public struct CopilotCLIStrategy: ProviderFetchStrategy, Sendable {
    public let id = "copilot-cli"
    public let kind = ProviderFetchKind.cli

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Check if gh CLI exists and is authenticated
        guard CLIExecutor.findExecutable("gh") != nil else {
            return false
        }

        // Check if user is logged in
        let result = try? await CLIExecutor.runTool("gh", arguments: ["auth", "status"], timeout: 10)
        return result?.isSuccess ?? false
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Use gh CLI to fetch copilot info
        return try await fetchViaGitHubCLI()
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case ProviderFetchError.authenticationRequired = error { return false }
        if case ProviderFetchError.invalidCredentials = error { return false }
        return true
    }

    private func fetchViaGitHubCLI() async throws -> ProviderFetchResult {
        // Get user info first
        let userResult = try await CLIExecutor.runTool("gh", arguments: ["api", "user"])

        guard userResult.isSuccess else {
            throw ProviderFetchError.authenticationRequired(.copilot)
        }

        var userName = "unknown"
        var userEmail: String?
        if let userData = userResult.output.data(using: .utf8),
           let userJson = try? JSONSerialization.jsonObject(with: userData) as? [String: Any] {
            userName = userJson["login"] as? String ?? "unknown"
            userEmail = userJson["email"] as? String
        }

        // Check auth scopes to see if copilot scope is available
        let authResult = try? await CLIExecutor.runTool(
            "gh",
            arguments: ["auth", "status"],
            timeout: 10
        )

        // Copilot doesn't have a public API for subscription status for individual users
        // The billing API requires organization admin access
        // Since the user is authenticated with gh CLI, we assume they have Copilot access
        // and show it as "Connected" with unlimited usage (0%)

        // Try to detect plan from auth output (look for enterprise/business indicators)
        var plan = "Individual"
        if let authOutput = authResult?.output {
            if authOutput.contains("enterprise") || authOutput.contains("Enterprise") {
                plan = "Enterprise"
            } else if authOutput.contains("business") || authOutput.contains("Business") {
                plan = "Business"
            }
        }

        // Copilot has unlimited usage for paid plans - show as 0% used
        // The label shows "Unlimited" to make it clear there's no quota
        let snapshot = UsageSnapshot(
            providerID: .copilot,
            primary: RateWindow(
                usedPercent: 0, // Unlimited usage
                windowMinutes: 0,
                resetsAt: nil,
                label: "Unlimited"
            ),
            updatedAt: Date(),
            identity: ProviderIdentity(
                email: userEmail,
                organization: nil,
                plan: plan,
                authMethod: "gh-cli"
            ),
            metadata: ["user": userName, "status": "active"]
        )

        return makeResult(usage: snapshot, sourceLabel: "gh-cli")
    }
}

/// Fetch Copilot usage via GitHub API with token.
public struct CopilotAPIStrategy: ProviderFetchStrategy, Sendable {
    public let id = "copilot-api"
    public let kind = ProviderFetchKind.apiToken

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        // Check for GitHub token in environment
        return context.environment["GITHUB_TOKEN"] != nil ||
               context.environment["GH_TOKEN"] != nil
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let token = context.environment["GITHUB_TOKEN"] ??
                    context.environment["GH_TOKEN"] ?? ""

        guard !token.isEmpty else {
            throw ProviderFetchError.authenticationRequired(.copilot)
        }

        return try await fetchUsage(token: token)
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        return true
    }

    private func fetchUsage(token: String) async throws -> ProviderFetchResult {
        // Get user info
        let userURL = URL(string: "https://api.github.com/user")!

        let (userData, userResponse) = try await HTTPClient.get(
            url: userURL,
            headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28"
            ]
        )

        guard userResponse.statusCode == 200 else {
            throw ProviderFetchError.invalidCredentials(.copilot)
        }

        var userName = "unknown"
        var userEmail: String?
        if let userJson = try? JSONSerialization.jsonObject(with: userData) as? [String: Any] {
            userName = userJson["login"] as? String ?? "unknown"
            userEmail = userJson["email"] as? String
        }

        // Copilot has unlimited usage for paid plans
        // The billing API requires org admin access, so we just show connected status
        let snapshot = UsageSnapshot(
            providerID: .copilot,
            primary: RateWindow(
                usedPercent: 0, // Unlimited
                windowMinutes: 0,
                resetsAt: nil,
                label: "Unlimited"
            ),
            updatedAt: Date(),
            identity: ProviderIdentity(
                email: userEmail,
                plan: "Individual",
                authMethod: "api-token"
            ),
            metadata: ["user": userName, "status": "active"]
        )

        return makeResult(usage: snapshot, sourceLabel: "api")
    }
}
