import AppKit
import ControlTowerCore
import Logging
import UserNotifications

#if ENABLE_SPARKLE
import Sparkle
#endif

/// Application delegate handling lifecycle, menu bar, and notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Stores

    let settingsStore: SettingsStore
    let usageStore: UsageStore
    let accountStore: AccountStore
    let notificationStore: NotificationHistoryStore

    // MARK: - Controllers

    private var statusItemController: StatusItemController?
    private var database: UsageDatabase?

    #if ENABLE_SPARKLE
    private var updaterController: SPUStandardUpdaterController?
    #endif

    // MARK: - Logging

    private let logger = Logger(label: "com.controltower.app")

    // MARK: - Initialization

    override init() {
        self.settingsStore = SettingsStore()
        self.usageStore = UsageStore()
        self.accountStore = AccountStore()
        self.notificationStore = NotificationHistoryStore()

        super.init()
    }

    // MARK: - Application Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Configure as menu bar only app (no dock icon)
        NSApp.setActivationPolicy(.accessory)

        self.logger.info("Control Tower launching...")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize database
        do {
            self.database = try UsageDatabase.open()
            self.usageStore.setDatabase(self.database!)
            self.logger.info("Database initialized")
        } catch {
            self.logger.error("Failed to initialize database: \(error)")
        }

        // Use real provider data
        self.usageStore.useMockData = false

        // Request notification permissions
        self.requestNotificationPermissions()

        // Setup Sparkle updater
        #if ENABLE_SPARKLE
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif

        // Create status bar controller
        self.statusItemController = StatusItemController(
            settingsStore: self.settingsStore,
            usageStore: self.usageStore,
            accountStore: self.accountStore
        )

        // Start initial refresh
        Task {
            await self.usageStore.refresh()
        }

        // Setup refresh timer
        self.setupRefreshTimer()

        self.logger.info("Control Tower ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.logger.info("Control Tower terminating...")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show menu when clicking dock icon (if visible)
        self.statusItemController?.showMenu()
        return false
    }

    // MARK: - Notifications

    private nonisolated func requestNotificationPermissions() {
        Task.detached {
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    // MARK: - Refresh Timer

    private var refreshTimer: Timer?

    private func setupRefreshTimer() {
        // Cancel existing timer
        self.refreshTimer?.invalidate()

        // Create new timer based on settings
        let interval = self.settingsStore.refreshInterval
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.usageStore.refresh()
            }
        }

        self.logger.info("Refresh timer set to \(Int(interval))s")
    }

    // MARK: - Actions

    func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshNow() {
        Task {
            await self.usageStore.refresh()
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Settings Store (Observable)

@MainActor
@Observable
final class SettingsStore {
    // General
    var refreshInterval: TimeInterval = 300
    var launchAtLogin: Bool = false

    // Providers
    var enabledProviders: Set<ProviderID> = Set(ProviderID.allCases)

    // Notifications
    var notifyAt80: Bool = true
    var notifyAt90: Bool = true
    var notifyAt95: Bool = true
    var notifyDepleted: Bool = true
    var notifyRestored: Bool = true
    var notifyWeeklySummary: Bool = false
    var respectDND: Bool = true

    // Advanced
    var debugMode: Bool = false

    init() {
        self.loadFromDefaults()
    }

    private func loadFromDefaults() {
        let defaults = UserDefaults.standard

        self.refreshInterval = defaults.double(forKey: "refreshInterval")
        if self.refreshInterval == 0 {
            self.refreshInterval = 300
        }

        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")

        if let providers = defaults.array(forKey: "enabledProviders") as? [String] {
            self.enabledProviders = Set(providers.compactMap { ProviderID(rawValue: $0) })
        }

        self.notifyAt80 = defaults.object(forKey: "notifyAt80") as? Bool ?? true
        self.notifyAt90 = defaults.object(forKey: "notifyAt90") as? Bool ?? true
        self.notifyAt95 = defaults.object(forKey: "notifyAt95") as? Bool ?? true
        self.notifyDepleted = defaults.object(forKey: "notifyDepleted") as? Bool ?? true
        self.notifyRestored = defaults.object(forKey: "notifyRestored") as? Bool ?? true
        self.notifyWeeklySummary = defaults.bool(forKey: "notifyWeeklySummary")
        self.respectDND = defaults.object(forKey: "respectDND") as? Bool ?? true
        self.debugMode = defaults.bool(forKey: "debugMode")
    }

    func saveToDefaults() {
        let defaults = UserDefaults.standard

        defaults.set(self.refreshInterval, forKey: "refreshInterval")
        defaults.set(self.launchAtLogin, forKey: "launchAtLogin")
        defaults.set(self.enabledProviders.map(\.rawValue), forKey: "enabledProviders")
        defaults.set(self.notifyAt80, forKey: "notifyAt80")
        defaults.set(self.notifyAt90, forKey: "notifyAt90")
        defaults.set(self.notifyAt95, forKey: "notifyAt95")
        defaults.set(self.notifyDepleted, forKey: "notifyDepleted")
        defaults.set(self.notifyRestored, forKey: "notifyRestored")
        defaults.set(self.notifyWeeklySummary, forKey: "notifyWeeklySummary")
        defaults.set(self.respectDND, forKey: "respectDND")
        defaults.set(self.debugMode, forKey: "debugMode")
    }
}

// MARK: - Usage Store (Observable)

@MainActor
@Observable
final class UsageStore {
    var snapshots: [ProviderID: UsageSnapshot] = [:]
    var errors: [ProviderID: String] = [:]
    var lastRefresh: Date?
    var isRefreshing: Bool = false
    var useMockData: Bool = false // Set to true to use mock data

    private var database: UsageDatabase?

    func setDatabase(_ db: UsageDatabase) {
        self.database = db
    }

    func refresh() async {
        self.isRefreshing = true
        defer { self.isRefreshing = false }

        if useMockData {
            // Generate mock data for testing
            for provider in ProviderID.allCases {
                self.snapshots[provider] = UsageSnapshot(
                    providerID: provider,
                    primary: RateWindow(
                        usedPercent: Double.random(in: 10...90),
                        usedTokens: Int.random(in: 1000...50000),
                        limitTokens: 100000,
                        windowMinutes: 300,
                        resetsAt: Date().addingTimeInterval(3600),
                        label: "Session"
                    ),
                    secondary: RateWindow(
                        usedPercent: Double.random(in: 5...50),
                        usedTokens: Int.random(in: 10000...200000),
                        limitTokens: 500000,
                        windowMinutes: 10080,
                        resetsAt: Date().addingTimeInterval(86400 * 3),
                        label: "Weekly"
                    ),
                    updatedAt: Date()
                )
                self.errors.removeValue(forKey: provider)
            }
        } else {
            // Fetch real data from providers
            let context = ProviderService.defaultAppContext()
            let results = await ProviderService.shared.fetchAll(context: context)

            for (provider, outcome) in results {
                switch outcome.result {
                case .success(let result):
                    self.snapshots[provider] = result.usage
                    self.errors.removeValue(forKey: provider)

                    // Record to database for analytics
                    if let db = database {
                        try? await db.recordUsage(result.usage)
                    }

                case .failure(let error):
                    self.errors[provider] = error.localizedDescription
                    // Keep old snapshot if available
                }
            }
        }

        self.lastRefresh = Date()
    }

    func refresh(provider: ProviderID) async {
        let context = ProviderService.defaultAppContext()
        let outcome = await ProviderService.shared.fetch(provider: provider, context: context)

        switch outcome.result {
        case .success(let result):
            self.snapshots[provider] = result.usage
            self.errors.removeValue(forKey: provider)

            if let db = database {
                try? await db.recordUsage(result.usage)
            }

        case .failure(let error):
            self.errors[provider] = error.localizedDescription
        }
    }
}

// MARK: - Account Store (Observable)

@MainActor
@Observable
final class AccountStore {
    var accounts: [ProviderID: [ProviderAccount]] = [:]
    var activeAccounts: [ProviderID: UUID] = [:]

    func accounts(for provider: ProviderID) -> [ProviderAccount] {
        self.accounts[provider] ?? []
    }

    func activeAccount(for provider: ProviderID) -> ProviderAccount? {
        guard let activeID = activeAccounts[provider] else { return nil }
        return accounts[provider]?.first { $0.id == activeID }
    }
}

// MARK: - Notification History Store (Observable)

@MainActor
@Observable
final class NotificationHistoryStore {
    var history: [NotificationRecord] = []

    func add(_ record: NotificationRecord) {
        self.history.insert(record, at: 0)
        if self.history.count > 100 {
            self.history = Array(self.history.prefix(100))
        }
    }
}
