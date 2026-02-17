import Foundation

/// Metadata describing a provider's display properties and capabilities.
public struct ProviderMetadata: Sendable {
    /// The provider identifier.
    public let id: ProviderID

    /// Human-readable display name.
    public let displayName: String

    /// Label for the primary (session) rate window.
    public let sessionLabel: String

    /// Label for the secondary (weekly/quota) rate window.
    public let quotaLabel: String

    /// Optional label for tertiary window (e.g., "Opus").
    public let tertiaryLabel: String?

    /// Whether this provider supports multiple rate tiers.
    public let supportsTertiary: Bool

    /// Whether this provider tracks credits/costs.
    public let supportsCredits: Bool

    /// Whether this provider supports multiple accounts.
    public let supportsMultiAccount: Bool

    /// URL to the provider's usage dashboard.
    public let dashboardURL: URL?

    /// URL to the provider's status page.
    public let statusPageURL: URL?

    /// Default refresh interval in seconds.
    public let defaultRefreshInterval: TimeInterval

    /// Toggle title for settings UI.
    public let toggleTitle: String

    /// Short description for the provider.
    public let description: String

    public init(
        id: ProviderID,
        displayName: String,
        sessionLabel: String = "Session",
        quotaLabel: String = "Weekly",
        tertiaryLabel: String? = nil,
        supportsTertiary: Bool = false,
        supportsCredits: Bool = false,
        supportsMultiAccount: Bool = true,
        dashboardURL: URL? = nil,
        statusPageURL: URL? = nil,
        defaultRefreshInterval: TimeInterval = 300,
        toggleTitle: String? = nil,
        description: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.sessionLabel = sessionLabel
        self.quotaLabel = quotaLabel
        self.tertiaryLabel = tertiaryLabel
        self.supportsTertiary = supportsTertiary
        self.supportsCredits = supportsCredits
        self.supportsMultiAccount = supportsMultiAccount
        self.dashboardURL = dashboardURL
        self.statusPageURL = statusPageURL
        self.defaultRefreshInterval = defaultRefreshInterval
        self.toggleTitle = toggleTitle ?? "Show \(displayName) usage"
        self.description = description
    }
}

/// Branding information for a provider (colors, icons).
public struct ProviderBranding: Sendable {
    /// Icon style identifier.
    public let iconStyle: IconStyle

    /// Resource name for the provider icon.
    public let iconResourceName: String

    /// Primary brand color.
    public let color: ProviderColor

    public init(
        iconStyle: IconStyle,
        iconResourceName: String,
        color: ProviderColor
    ) {
        self.iconStyle = iconStyle
        self.iconResourceName = iconResourceName
        self.color = color
    }
}

/// RGB color representation for provider branding.
public struct ProviderColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Common provider colors
    public static let claude = ProviderColor(red: 0.85, green: 0.55, blue: 0.35)
    public static let codex = ProviderColor(red: 0.0, green: 0.65, blue: 0.52)
    public static let cursor = ProviderColor(red: 0.4, green: 0.4, blue: 0.9)
    public static let gemini = ProviderColor(red: 0.26, green: 0.52, blue: 0.96)
    public static let copilot = ProviderColor(red: 0.0, green: 0.47, blue: 0.84)
}

/// Authentication methods supported by a provider.
public enum AuthMethod: String, Sendable, Codable, CaseIterable {
    case oauth
    case apiKey
    case cookies
    case cli

    public var displayName: String {
        switch self {
        case .oauth: "OAuth"
        case .apiKey: "API Key"
        case .cookies: "Browser Cookies"
        case .cli: "CLI"
        }
    }
}

/// Configuration for OAuth authentication.
public struct OAuthConfig: Sendable {
    public let authorizationURL: URL
    public let tokenURL: URL
    public let clientID: String
    public let scopes: [String]
    public let keychainService: String

    public init(
        authorizationURL: URL,
        tokenURL: URL,
        clientID: String,
        scopes: [String],
        keychainService: String
    ) {
        self.authorizationURL = authorizationURL
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.scopes = scopes
        self.keychainService = keychainService
    }
}

/// Configuration for API key authentication.
public struct APIKeyConfig: Sendable {
    public let environmentVariable: String
    public let keychainKey: String
    public let placeholder: String

    public init(
        environmentVariable: String,
        keychainKey: String,
        placeholder: String = "Enter API key..."
    ) {
        self.environmentVariable = environmentVariable
        self.keychainKey = keychainKey
        self.placeholder = placeholder
    }
}

/// Configuration for cookie-based authentication.
public struct CookieConfig: Sendable {
    public let domains: [String]
    public let requiredCookies: [String]
    public let browserOrder: [Browser]

    public init(
        domains: [String],
        requiredCookies: [String],
        browserOrder: [Browser] = Browser.defaultOrder
    ) {
        self.domains = domains
        self.requiredCookies = requiredCookies
        self.browserOrder = browserOrder
    }
}

/// Supported browsers for cookie import.
public enum Browser: String, Sendable, CaseIterable, Codable {
    case chrome
    case chromeBeta
    case chromeCanary
    case arc
    case safari
    case firefox
    case brave
    case edge
    case vivaldi
    case opera

    public var displayName: String {
        switch self {
        case .chrome: "Chrome"
        case .chromeBeta: "Chrome Beta"
        case .chromeCanary: "Chrome Canary"
        case .arc: "Arc"
        case .safari: "Safari"
        case .firefox: "Firefox"
        case .brave: "Brave"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        }
    }

    /// Default import order - Chrome-based browsers first
    public static let defaultOrder: [Browser] = [.chrome, .arc, .brave, .edge, .chromeBeta, .vivaldi, .opera]
    public static var defaultImportOrder: [Browser] { defaultOrder }

    /// Cookie database path
    public var cookiePath: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        switch self {
        case .chrome:
            return home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cookies")
        case .chromeBeta:
            return home.appendingPathComponent("Library/Application Support/Google/Chrome Beta/Default/Cookies")
        case .chromeCanary:
            return home.appendingPathComponent("Library/Application Support/Google/Chrome Canary/Default/Cookies")
        case .brave:
            return home.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies")
        case .edge:
            return home.appendingPathComponent("Library/Application Support/Microsoft Edge/Default/Cookies")
        case .arc:
            return home.appendingPathComponent("Library/Application Support/Arc/User Data/Default/Cookies")
        case .vivaldi:
            return home.appendingPathComponent("Library/Application Support/Vivaldi/Default/Cookies")
        case .opera:
            return home.appendingPathComponent("Library/Application Support/com.operasoftware.Opera/Default/Cookies")
        case .firefox, .safari:
            return nil // Not Chromium-based
        }
    }

    /// Keychain service name for the browser's encryption key
    public var keychainService: String {
        switch self {
        case .chrome, .chromeBeta, .chromeCanary:
            return "Chrome Safe Storage"
        case .brave:
            return "Brave Safe Storage"
        case .edge:
            return "Microsoft Edge Safe Storage"
        case .arc:
            return "Arc Safe Storage"
        case .vivaldi:
            return "Vivaldi Safe Storage"
        case .opera:
            return "Opera Safe Storage"
        case .firefox, .safari:
            return ""
        }
    }

    public var isChromiumBased: Bool {
        switch self {
        case .firefox, .safari:
            return false
        default:
            return true
        }
    }

    public var isInstalled: Bool {
        guard let path = cookiePath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }
}
