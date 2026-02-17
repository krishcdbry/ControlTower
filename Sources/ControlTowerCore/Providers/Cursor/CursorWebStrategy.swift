import Foundation

/// Fetch Cursor usage via web API with cookies.
public struct CursorWebStrategy: ProviderFetchStrategy, Sendable {
    public let id = "cursor-web"
    public let kind = ProviderFetchKind.web

    private static let cookieClient = BrowserCookieClient()
    private static let sessionCookieNames: Set<String> = [
        "WorkosCursorSessionToken",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
    ]
    private static let cookieDomains = ["cursor.com", "cursor.sh"]

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.cookieSource != .off else { return false }

        do {
            let _ = try Self.importSession()
            return true
        } catch {
            return false
        }
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        // Get session cookies
        let session: SessionInfo
        do {
            session = try Self.importSession()
        } catch {
            // Build helpful error message with browser list
            let browsers = Browser.defaultImportOrder.map { $0.displayName }.joined(separator: ", ")
            throw ProviderFetchError.authenticationRequired(
                .cursor,
                message: "No Cursor session found. Please log in to cursor.com in \(browsers)."
            )
        }

        return try await fetchUsage(cookieHeader: session.cookieHeader, sourceLabel: session.sourceLabel)
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case ProviderFetchError.authenticationRequired = error { return false }
        if case ProviderFetchError.invalidCredentials = error { return false }
        return true
    }

    // MARK: - Cookie Import

    private struct SessionInfo: Sendable {
        let cookies: [HTTPCookie]
        let sourceLabel: String

        var cookieHeader: String {
            cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
    }

    private static func importSession() throws -> SessionInfo {
        let query = BrowserCookieClient.CookieQuery(domains: cookieDomains)

        for browser in Browser.defaultImportOrder {
            guard browser.isInstalled else { continue }

            do {
                let sources = try cookieClient.records(matching: query, in: browser)
                for source in sources where !source.records.isEmpty {
                    let httpCookies = BrowserCookieClient.makeHTTPCookies(source.records, origin: query.origin)
                    if httpCookies.contains(where: { sessionCookieNames.contains($0.name) }) {
                        return SessionInfo(cookies: httpCookies, sourceLabel: source.label)
                    }
                }
            } catch {
                // Try next browser
                continue
            }
        }

        throw CursorSessionError.noSessionCookie
    }

    // MARK: - API Fetch

    private func fetchUsage(cookieHeader: String, sourceLabel: String) async throws -> ProviderFetchResult {
        // Fetch user info and usage summary in parallel
        async let userInfoTask = fetchUserInfo(cookieHeader: cookieHeader)
        async let usageSummaryTask = fetchUsageSummary(cookieHeader: cookieHeader)

        let userInfo = try await userInfoTask
        let usageSummary = try await usageSummaryTask

        return parseUsageSummary(usageSummary, userInfo: userInfo, sourceLabel: sourceLabel)
    }

    private struct UserInfo {
        let id: String?
        let email: String?
        let name: String?
        let sub: String?
    }

    private func fetchUserInfo(cookieHeader: String) async throws -> UserInfo {
        let url = URL(string: "https://www.cursor.com/api/auth/me")!

        let (data, response) = try await HTTPClient.get(
            url: url,
            headers: [
                "Cookie": cookieHeader,
                "Accept": "application/json",
                "User-Agent": "ControlTower/1.0"
            ]
        )

        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderFetchError.invalidCredentials(.cursor)
            }
            return UserInfo(id: nil, email: nil, name: nil, sub: nil)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return UserInfo(id: nil, email: nil, name: nil, sub: nil)
        }

        return UserInfo(
            id: json["id"] as? String,
            email: json["email"] as? String,
            name: json["name"] as? String,
            sub: json["sub"] as? String
        )
    }

    /// Fetch from the NEW /api/usage-summary endpoint (credits-based plans)
    private func fetchUsageSummary(cookieHeader: String) async throws -> [String: Any] {
        let url = URL(string: "https://www.cursor.com/api/usage-summary")!

        let (data, response) = try await HTTPClient.get(
            url: url,
            headers: [
                "Cookie": cookieHeader,
                "Accept": "application/json",
                "User-Agent": "ControlTower/1.0"
            ]
        )

        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderFetchError.invalidCredentials(.cursor)
            }
            throw HTTPError.httpError(response.statusCode, nil)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderFetchError.parseError("Invalid usage-summary response")
        }

        return json
    }

    private func parseUsageSummary(_ json: [String: Any], userInfo: UserInfo, sourceLabel: String) -> ProviderFetchResult {
        // Parse billing cycle end date
        var billingCycleEnd: Date? = nil
        if let endDateStr = json["billingCycleEnd"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            billingCycleEnd = formatter.date(from: endDateStr) ?? ISO8601DateFormatter().date(from: endDateStr)
        }

        // Parse plan usage (credits-based)
        var planUsedCents = 0
        var planLimitCents = 0
        var planPercentUsed: Double = 0

        if let individual = json["individualUsage"] as? [String: Any],
           let plan = individual["plan"] as? [String: Any] {
            planUsedCents = plan["used"] as? Int ?? 0
            planLimitCents = plan["limit"] as? Int ?? 0

            // Calculate percent used from raw values
            if planLimitCents > 0 {
                planPercentUsed = (Double(planUsedCents) / Double(planLimitCents)) * 100
            } else if let totalPercent = plan["totalPercentUsed"] as? Double {
                // Normalize: API might return 0-1 or 0-100
                planPercentUsed = totalPercent <= 1 ? totalPercent * 100 : totalPercent
            }
        }

        // Parse on-demand usage
        var onDemandUsedCents = 0
        var onDemandLimitCents: Int? = nil

        if let individual = json["individualUsage"] as? [String: Any],
           let onDemand = individual["onDemand"] as? [String: Any] {
            onDemandUsedCents = onDemand["used"] as? Int ?? 0
            onDemandLimitCents = onDemand["limit"] as? Int
        }

        let membershipType = json["membershipType"] as? String

        // Convert to dollars (only on-demand values are used for now)
        let onDemandUsedDollars = Double(onDemandUsedCents) / 100.0
        let onDemandLimitDollars = onDemandLimitCents.map { Double($0) / 100.0 }

        // Build primary rate window (plan usage)
        let primary = RateWindow(
            usedPercent: planPercentUsed,
            resetsAt: billingCycleEnd,
            label: "Plan"
        )

        // Build secondary rate window (on-demand credits) if applicable
        var secondary: RateWindow? = nil
        if onDemandUsedCents > 0 || onDemandLimitCents != nil {
            let onDemandPercent: Double
            if let limit = onDemandLimitDollars, limit > 0 {
                onDemandPercent = (onDemandUsedDollars / limit) * 100
            } else {
                onDemandPercent = 0
            }

            let creditsLabel: String
            if let limit = onDemandLimitDollars {
                creditsLabel = String(format: "$%.2f / $%.2f", onDemandUsedDollars, limit)
            } else {
                creditsLabel = String(format: "$%.2f used", onDemandUsedDollars)
            }

            secondary = RateWindow(
                usedPercent: onDemandPercent,
                resetsAt: billingCycleEnd,
                label: creditsLabel
            )
        }

        // Format plan name
        let planName: String?
        if let membership = membershipType {
            switch membership.lowercased() {
            case "free", "hobby":
                planName = "Cursor Free"
            case "pro":
                planName = "Cursor Pro"
            case "enterprise":
                planName = "Cursor Enterprise"
            case "team":
                planName = "Cursor Team"
            default:
                planName = "Cursor \(membership.capitalized)"
            }
        } else {
            planName = nil
        }

        let snapshot = UsageSnapshot(
            providerID: .cursor,
            primary: primary,
            secondary: secondary,
            updatedAt: Date(),
            identity: ProviderIdentity(
                email: userInfo.email,
                plan: planName,
                authMethod: "web"
            )
        )

        return makeResult(usage: snapshot, sourceLabel: sourceLabel)
    }
}

// MARK: - Errors

private enum CursorSessionError: LocalizedError {
    case noSessionCookie

    var errorDescription: String? {
        switch self {
        case .noSessionCookie:
            return "No Cursor session cookie found"
        }
    }
}
