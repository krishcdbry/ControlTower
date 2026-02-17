import Foundation
import GRDB

/// SQLite database for persisting usage analytics and notification history.
public final class UsageDatabase: Sendable {
    private let dbPool: DatabasePool

    /// Database path for the app.
    public static var defaultPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ControlTower", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("usage.db")
    }

    /// Opens or creates the database at the given path.
    public static func open(at path: URL = defaultPath) throws -> UsageDatabase {
        var config = Configuration()
        config.prepareDatabase { db in
            // Enable foreign keys
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let dbPool = try DatabasePool(path: path.path, configuration: config)
        let database = UsageDatabase(dbPool: dbPool)
        try database.migrate()
        return database
    }

    private init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Run all pending migrations.
    private func migrate() throws {
        var migrator = DatabaseMigrator()

        // v1: Initial schema
        migrator.registerMigration("v1_initial") { db in
            // Usage records table
            try db.create(table: "usage_records") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("provider", .text).notNull()
                t.column("account_id", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("primary_used_percent", .double)
                t.column("secondary_used_percent", .double)
                t.column("cost_usd", .double)
                t.column("tokens_used", .integer)
                t.column("models_json", .text)
            }
            try db.create(
                index: "idx_usage_provider_ts",
                on: "usage_records",
                columns: ["provider", "timestamp"]
            )

            // Accounts table
            try db.create(table: "accounts") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull()
                t.column("email", .text)
                t.column("display_name", .text).notNull()
                t.column("auth_method", .text).notNull()
                t.column("keychain_id", .text).notNull()
                t.column("is_active", .boolean).notNull().defaults(to: false)
                t.column("added_at", .datetime).notNull()
                t.column("last_used_at", .datetime)
            }
            try db.create(
                index: "idx_accounts_provider",
                on: "accounts",
                columns: ["provider"]
            )

            // Notification history table
            try db.create(table: "notification_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("was_delivered", .boolean).notNull().defaults(to: true)
                t.column("metadata_json", .text)
            }
            try db.create(
                index: "idx_notifications_ts",
                on: "notification_history",
                columns: ["timestamp"]
            )
        }

        try migrator.migrate(dbPool)
    }

    // MARK: - Usage Records

    /// Record a usage data point.
    public func recordUsage(_ dataPoint: UsageDataPoint) async throws {
        try await dbPool.write { db in
            let record = UsageRecord(from: dataPoint)
            try record.insert(db)
        }
    }

    /// Get usage records for a provider within a date range.
    public func usageRecords(
        provider: ProviderID,
        from startDate: Date,
        to endDate: Date,
        limit: Int? = nil
    ) async throws -> [UsageDataPoint] {
        try await dbPool.read { db in
            var query = UsageRecord
                .filter(UsageRecord.Columns.provider == provider.rawValue)
                .filter(UsageRecord.Columns.timestamp >= startDate)
                .filter(UsageRecord.Columns.timestamp <= endDate)
                .order(UsageRecord.Columns.timestamp.desc)

            if let limit {
                query = query.limit(limit)
            }

            return try query.fetchAll(db).map { $0.toDataPoint() }
        }
    }

    /// Get the most recent usage record for a provider.
    public func latestUsage(provider: ProviderID) async throws -> UsageDataPoint? {
        try await dbPool.read { db in
            try UsageRecord
                .filter(UsageRecord.Columns.provider == provider.rawValue)
                .order(UsageRecord.Columns.timestamp.desc)
                .fetchOne(db)?
                .toDataPoint()
        }
    }

    /// Delete usage records older than a given date.
    public func pruneUsageRecords(olderThan date: Date) async throws -> Int {
        try await dbPool.write { db in
            try UsageRecord
                .filter(UsageRecord.Columns.timestamp < date)
                .deleteAll(db)
        }
    }

    // MARK: - Accounts

    /// Save an account.
    public func saveAccount(_ account: ProviderAccount) async throws {
        try await dbPool.write { db in
            let record = AccountRecord(from: account)
            try record.save(db)
        }
    }

    /// Get all accounts for a provider.
    public func accounts(for provider: ProviderID) async throws -> [ProviderAccount] {
        try await dbPool.read { db in
            try AccountRecord
                .filter(AccountRecord.Columns.provider == provider.rawValue)
                .order(AccountRecord.Columns.addedAt.desc)
                .fetchAll(db)
                .map { $0.toAccount() }
        }
    }

    /// Delete an account.
    public func deleteAccount(id: UUID) async throws -> Bool {
        try await dbPool.write { db in
            try AccountRecord
                .filter(AccountRecord.Columns.id == id.uuidString)
                .deleteAll(db) > 0
        }
    }

    /// Set the active account for a provider.
    public func setActiveAccount(id: UUID, provider: ProviderID) async throws {
        try await dbPool.write { db in
            // Deactivate all accounts for this provider
            try db.execute(
                sql: "UPDATE accounts SET is_active = 0 WHERE provider = ?",
                arguments: [provider.rawValue]
            )
            // Activate the selected account
            try db.execute(
                sql: "UPDATE accounts SET is_active = 1, last_used_at = ? WHERE id = ?",
                arguments: [Date(), id.uuidString]
            )
        }
    }

    // MARK: - Notification History

    /// Record a notification.
    public func recordNotification(_ record: NotificationRecord) async throws {
        try await dbPool.write { db in
            let dbRecord = NotificationDBRecord(from: record)
            try dbRecord.insert(db)
        }
    }

    /// Get notification history.
    public func notificationHistory(
        provider: ProviderID? = nil,
        limit: Int = 100
    ) async throws -> [NotificationRecord] {
        try await dbPool.read { db in
            var query = NotificationDBRecord.all()
                .order(NotificationDBRecord.Columns.timestamp.desc)
                .limit(limit)

            if let provider {
                query = query.filter(NotificationDBRecord.Columns.provider == provider.rawValue)
            }

            return try query.fetchAll(db).map { $0.toRecord() }
        }
    }

    /// Check if a notification type is in cooldown.
    public func isInCooldown(
        type: NotificationType,
        provider: ProviderID,
        cooldownMinutes: Int
    ) async throws -> Bool {
        let cutoff = Date().addingTimeInterval(-Double(cooldownMinutes * 60))
        return try await dbPool.read { db in
            let count = try NotificationDBRecord
                .filter(NotificationDBRecord.Columns.type == type.rawValue)
                .filter(NotificationDBRecord.Columns.provider == provider.rawValue)
                .filter(NotificationDBRecord.Columns.timestamp >= cutoff)
                .fetchCount(db)
            return count > 0
        }
    }

    /// Delete old notification records.
    public func pruneNotifications(olderThan days: Int) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days * 86400))
        return try await dbPool.write { db in
            try NotificationDBRecord
                .filter(NotificationDBRecord.Columns.timestamp < cutoff)
                .deleteAll(db)
        }
    }

    // MARK: - Analytics Methods

    /// Record a usage snapshot.
    public func recordUsage(_ snapshot: UsageSnapshot) async throws {
        try await dbPool.write { db in
            let record = UsageRecord(fromSnapshot: snapshot)
            try record.insert(db)
        }
    }

    /// Fetch usage history for a provider.
    public func fetchUsageHistory(provider: ProviderID, days: Int) async throws -> [UsageDataPoint] {
        let cutoff = Date().addingTimeInterval(-Double(days * 86400))
        return try await dbPool.read { db in
            try UsageRecord
                .filter(UsageRecord.Columns.provider == provider.rawValue)
                .filter(UsageRecord.Columns.timestamp >= cutoff)
                .order(UsageRecord.Columns.timestamp.asc)
                .fetchAll(db)
                .map { $0.toUsageDataPoint() }
        }
    }

    /// Fetch daily aggregated usage.
    public func fetchDailyUsage(provider: ProviderID, days: Int) async throws -> [DailyUsageSummary] {
        let cutoff = Date().addingTimeInterval(-Double(days * 86400))
        return try await dbPool.read { db in
            // Group by date and aggregate
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    date(timestamp) as day,
                    provider,
                    avg(primary_used_percent) as avg_percent,
                    max(primary_used_percent) as max_percent,
                    sum(tokens_used) as total_tokens,
                    sum(cost_usd) as total_cost
                FROM usage_records
                WHERE provider = ? AND timestamp >= ?
                GROUP BY date(timestamp), provider
                ORDER BY day ASC
                """, arguments: [provider.rawValue, cutoff])

            return rows.compactMap { row -> DailyUsageSummary? in
                guard let dayStr = row["day"] as? String,
                      let avgPercent = row["avg_percent"] as? Double else {
                    return nil
                }

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                guard let date = dateFormatter.date(from: dayStr) else { return nil }

                return DailyUsageSummary(
                    date: date,
                    provider: provider,
                    avgUsedPercent: avgPercent,
                    maxUsedPercent: row["max_percent"] as? Double ?? avgPercent,
                    totalTokens: row["total_tokens"] as? Int ?? 0,
                    totalCostUSD: row["total_cost"] as? Double ?? 0
                )
            }
        }
    }

    /// Fetch latest usage for a provider.
    public func fetchLatestUsage(provider: ProviderID) async throws -> UsageDataPoint? {
        try await latestUsage(provider: provider)
    }

    /// Fetch all usage history across providers.
    public func fetchAllUsageHistory(days: Int) async throws -> [UsageDataPoint] {
        let cutoff = Date().addingTimeInterval(-Double(days * 86400))
        return try await dbPool.read { db in
            try UsageRecord
                .filter(UsageRecord.Columns.timestamp >= cutoff)
                .order(UsageRecord.Columns.timestamp.asc)
                .fetchAll(db)
                .map { $0.toUsageDataPoint() }
        }
    }

    /// Fetch total tokens used across all providers.
    public func fetchTotalTokens(days: Int) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days * 86400))
        return try await dbPool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT sum(tokens_used) as total FROM usage_records WHERE timestamp >= ?
                """, arguments: [cutoff])
            return row?["total"] as? Int ?? 0
        }
    }

    /// Fetch cost summary.
    public func fetchCostSummary(days: Int) async throws -> CostSummary {
        let cutoff = Date().addingTimeInterval(-Double(days * 86400))
        return try await dbPool.read { db in
            // Total and by provider
            let byProviderRows = try Row.fetchAll(db, sql: """
                SELECT provider, sum(cost_usd) as total FROM usage_records
                WHERE timestamp >= ? GROUP BY provider
                """, arguments: [cutoff])

            var costByProvider: [ProviderID: Double] = [:]
            var totalCost: Double = 0
            for row in byProviderRows {
                if let providerStr = row["provider"] as? String,
                   let provider = ProviderID(rawValue: providerStr),
                   let cost = row["total"] as? Double {
                    costByProvider[provider] = cost
                    totalCost += cost
                }
            }

            // Daily costs
            let dailyRows = try Row.fetchAll(db, sql: """
                SELECT date(timestamp) as day, sum(cost_usd) as total FROM usage_records
                WHERE timestamp >= ? GROUP BY date(timestamp) ORDER BY day ASC
                """, arguments: [cutoff])

            var dailyCosts: [Date: Double] = [:]
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            for row in dailyRows {
                if let dayStr = row["day"] as? String,
                   let date = dateFormatter.date(from: dayStr),
                   let cost = row["total"] as? Double {
                    dailyCosts[date] = cost
                }
            }

            return CostSummary(
                totalCostUSD: totalCost,
                costByProvider: costByProvider,
                dailyCosts: dailyCosts,
                periodDays: days
            )
        }
    }
}

// MARK: - Database Records

/// GRDB record for usage data.
private struct UsageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "usage_records"

    var id: Int64?
    var provider: String
    var accountID: String?
    var timestamp: Date
    var primaryUsedPercent: Double?
    var secondaryUsedPercent: Double?
    var costUSD: Double?
    var tokensUsed: Int?
    var modelsJSON: String?

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let provider = Column(CodingKeys.provider)
        static let accountID = Column(CodingKeys.accountID)
        static let timestamp = Column(CodingKeys.timestamp)
        static let primaryUsedPercent = Column(CodingKeys.primaryUsedPercent)
        static let secondaryUsedPercent = Column(CodingKeys.secondaryUsedPercent)
        static let costUSD = Column(CodingKeys.costUSD)
        static let tokensUsed = Column(CodingKeys.tokensUsed)
        static let modelsJSON = Column(CodingKeys.modelsJSON)
    }

    init(from dataPoint: UsageDataPoint) {
        self.id = dataPoint.id
        self.provider = dataPoint.provider.rawValue
        self.accountID = dataPoint.accountID?.uuidString
        self.timestamp = dataPoint.timestamp
        self.primaryUsedPercent = dataPoint.primaryUsedPercent
        self.secondaryUsedPercent = dataPoint.secondaryUsedPercent
        self.costUSD = dataPoint.costUSD
        self.tokensUsed = dataPoint.tokensUsed
        if let models = dataPoint.modelsUsed {
            self.modelsJSON = try? String(data: JSONEncoder().encode(models), encoding: .utf8)
        } else {
            self.modelsJSON = nil
        }
    }

    init(fromSnapshot snapshot: UsageSnapshot) {
        self.id = nil
        self.provider = snapshot.providerID.rawValue
        self.accountID = snapshot.accountID?.uuidString
        self.timestamp = snapshot.updatedAt
        self.primaryUsedPercent = snapshot.primary?.usedPercent
        self.secondaryUsedPercent = snapshot.secondary?.usedPercent
        self.costUSD = snapshot.cost?.dailyCostUSD
        self.tokensUsed = snapshot.primary?.usedTokens
        self.modelsJSON = nil
    }

    func toDataPoint() -> UsageDataPoint {
        var models: [String]?
        if let json = modelsJSON, let data = json.data(using: .utf8) {
            models = try? JSONDecoder().decode([String].self, from: data)
        }
        return UsageDataPoint(
            id: id,
            timestamp: timestamp,
            provider: ProviderID(rawValue: provider) ?? .claude,
            accountID: accountID.flatMap { UUID(uuidString: $0) },
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            costUSD: costUSD,
            tokensUsed: tokensUsed,
            modelsUsed: models
        )
    }

    func toUsageDataPoint() -> UsageDataPoint {
        toDataPoint()
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }
}

/// GRDB record for accounts.
private struct AccountRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "accounts"

    var id: String
    var provider: String
    var email: String?
    var displayName: String
    var authMethod: String
    var keychainID: String
    var isActive: Bool
    var addedAt: Date
    var lastUsedAt: Date?

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let provider = Column(CodingKeys.provider)
        static let email = Column(CodingKeys.email)
        static let displayName = Column(CodingKeys.displayName)
        static let authMethod = Column(CodingKeys.authMethod)
        static let keychainID = Column(CodingKeys.keychainID)
        static let isActive = Column(CodingKeys.isActive)
        static let addedAt = Column(CodingKeys.addedAt)
        static let lastUsedAt = Column(CodingKeys.lastUsedAt)
    }

    init(from account: ProviderAccount) {
        self.id = account.id.uuidString
        self.provider = account.providerID.rawValue
        self.email = account.email
        self.displayName = account.displayName
        self.authMethod = account.authMethod.rawValue
        self.keychainID = account.keychainID
        self.isActive = account.isActive
        self.addedAt = account.addedAt
        self.lastUsedAt = account.lastUsedAt
    }

    func toAccount() -> ProviderAccount {
        ProviderAccount(
            id: UUID(uuidString: id) ?? UUID(),
            providerID: ProviderID(rawValue: provider) ?? .claude,
            email: email,
            displayName: displayName,
            authMethod: AuthMethod(rawValue: authMethod) ?? .oauth,
            keychainID: keychainID,
            isActive: isActive,
            addedAt: addedAt,
            lastUsedAt: lastUsedAt
        )
    }
}

/// GRDB record for notifications.
private struct NotificationDBRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notification_history"

    var id: Int64?
    var type: String
    var provider: String
    var title: String
    var body: String
    var timestamp: Date
    var wasDelivered: Bool
    var metadataJSON: String?

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let type = Column(CodingKeys.type)
        static let provider = Column(CodingKeys.provider)
        static let title = Column(CodingKeys.title)
        static let body = Column(CodingKeys.body)
        static let timestamp = Column(CodingKeys.timestamp)
        static let wasDelivered = Column(CodingKeys.wasDelivered)
        static let metadataJSON = Column(CodingKeys.metadataJSON)
    }

    init(from record: NotificationRecord) {
        self.id = nil
        self.type = record.type.rawValue
        self.provider = record.provider.rawValue
        self.title = record.title
        self.body = record.body
        self.timestamp = record.timestamp
        self.wasDelivered = record.wasDelivered
        if !record.metadata.isEmpty {
            self.metadataJSON = try? String(data: JSONEncoder().encode(record.metadata), encoding: .utf8)
        } else {
            self.metadataJSON = nil
        }
    }

    func toRecord() -> NotificationRecord {
        var metadata: [String: String] = [:]
        if let json = metadataJSON, let data = json.data(using: .utf8) {
            metadata = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        return NotificationRecord(
            id: id.map { _ in UUID() } ?? UUID(),
            type: NotificationType(rawValue: type) ?? .quotaWarning,
            provider: ProviderID(rawValue: provider) ?? .claude,
            title: title,
            body: body,
            timestamp: timestamp,
            wasDelivered: wasDelivered,
            metadata: metadata
        )
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }
}
