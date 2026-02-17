import Foundation

/// A provider account with credentials stored in Keychain.
public struct ProviderAccount: Sendable, Identifiable, Codable, Equatable {
    /// Unique identifier for this account.
    public let id: UUID

    /// The provider this account belongs to.
    public let providerID: ProviderID

    /// Email address, if known.
    public let email: String?

    /// User-friendly display name.
    public let displayName: String

    /// How this account authenticates.
    public let authMethod: AuthMethod

    /// Reference to credentials in Keychain.
    public let keychainID: String

    /// Whether this is the currently active account for the provider.
    public var isActive: Bool

    /// When this account was added.
    public let addedAt: Date

    /// When this account was last used.
    public var lastUsedAt: Date?

    public init(
        id: UUID = UUID(),
        providerID: ProviderID,
        email: String? = nil,
        displayName: String,
        authMethod: AuthMethod,
        keychainID: String,
        isActive: Bool = false,
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.email = email
        self.displayName = displayName
        self.authMethod = authMethod
        self.keychainID = keychainID
        self.isActive = isActive
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
    }

    /// Returns a display label, preferring email over display name.
    public var label: String {
        self.email ?? self.displayName
    }
}

/// Persisted account data for a provider.
public struct ProviderAccountData: Sendable, Codable {
    /// Schema version for migrations.
    public let version: Int

    /// All accounts for this provider.
    public var accounts: [ProviderAccount]

    /// Index of the currently active account.
    public var activeIndex: Int

    public init(version: Int = 1, accounts: [ProviderAccount] = [], activeIndex: Int = 0) {
        self.version = version
        self.accounts = accounts
        self.activeIndex = activeIndex
    }

    /// Returns the currently active account, if any.
    public var activeAccount: ProviderAccount? {
        guard activeIndex >= 0, activeIndex < accounts.count else { return nil }
        return accounts[activeIndex]
    }
}

/// Usage snapshot for a specific account.
public struct AccountUsageSnapshot: Sendable, Identifiable {
    public var id: UUID { self.account.id }

    /// The account this snapshot belongs to.
    public let account: ProviderAccount

    /// The usage data for this account.
    public let usage: UsageSnapshot

    /// When this snapshot was fetched.
    public let fetchedAt: Date

    public init(account: ProviderAccount, usage: UsageSnapshot, fetchedAt: Date = Date()) {
        self.account = account
        self.usage = usage
        self.fetchedAt = fetchedAt
    }
}
