import ControlTowerCore
import SwiftUI

#if ENABLE_SPARKLE
import Sparkle
#endif

/// Main entry point for Control Tower.
@main
struct ControlTowerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window
        Settings {
            PreferencesView(
                settings: self.appDelegate.settingsStore,
                usageStore: self.appDelegate.usageStore
            )
        }

        // Hidden window to keep the app alive
        Window("Control Tower", id: "hidden") {
            HiddenWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Hidden window view to keep SwiftUI lifecycle alive.
struct HiddenWindowView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                // Hide the window immediately
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "hidden" }) {
                    window.orderOut(nil)
                }
            }
    }
}

/// Placeholder preferences view - will be expanded later.
struct PreferencesView: View {
    @Bindable var settings: SettingsStore
    @Bindable var usageStore: UsageStore

    var body: some View {
        TabView {
            GeneralPane(settings: self.settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ProvidersPane(settings: self.settings, usageStore: self.usageStore)
                .tabItem {
                    Label("Providers", systemImage: "cpu")
                }

            NotificationsPane(settings: self.settings)
                .tabItem {
                    Label("Notifications", systemImage: "bell")
                }

            AboutPane()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 550, height: 520)
    }
}

// MARK: - Preference Panes (Placeholders)

struct GeneralPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Refresh Settings
                SettingsSection(title: "Refresh", icon: "arrow.clockwise", iconColor: .blue) {
                    VStack(spacing: 0) {
                        SettingsPicker(
                            title: "Refresh interval",
                            subtitle: "How often to fetch usage data",
                            selection: self.$settings.refreshInterval
                        ) {
                            Text("1 minute").tag(60.0)
                            Text("2 minutes").tag(120.0)
                            Text("5 minutes").tag(300.0)
                            Text("15 minutes").tag(900.0)
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                }

                // Startup Settings
                SettingsSection(title: "Startup", icon: "power", iconColor: .green) {
                    VStack(spacing: 0) {
                        SettingsToggle(
                            title: "Launch at login",
                            subtitle: "Start Control Tower when you log in",
                            isOn: self.$settings.launchAtLogin
                        )
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                }

                // Debug Settings
                SettingsSection(title: "Advanced", icon: "wrench.and.screwdriver", iconColor: .gray) {
                    VStack(spacing: 0) {
                        SettingsToggle(
                            title: "Debug mode",
                            subtitle: "Show additional diagnostic information",
                            isOn: self.$settings.debugMode
                        )
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                }

                Spacer()
            }
            .padding()
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: self.icon)
                    .foregroundStyle(self.iconColor)
                Text(self.title)
                    .font(.headline)
            }
            .padding(.horizontal, 4)

            self.content
        }
    }
}

struct SettingsToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.body)
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: self.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct SettingsPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    let subtitle: String
    @Binding var selection: SelectionValue
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.body)
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: self.$selection) {
                self.content
            }
            .labelsHidden()
            .frame(width: 130)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct ProvidersPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var usageStore: UsageStore
    @State private var expandedProvider: ProviderID?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(ProviderID.allCases, id: \.self) { provider in
                    ProviderCard(
                        provider: provider,
                        settings: self.settings,
                        usageStore: self.usageStore,
                        isExpanded: self.expandedProvider == provider,
                        onToggleExpand: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if self.expandedProvider == provider {
                                    self.expandedProvider = nil
                                } else {
                                    self.expandedProvider = provider
                                }
                            }
                        }
                    )
                }
            }
            .padding()
        }
    }
}

// MARK: - Provider Card

struct ProviderCard: View {
    let provider: ProviderID
    @Bindable var settings: SettingsStore
    @Bindable var usageStore: UsageStore
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    private var isEnabled: Bool {
        self.settings.enabledProviders.contains(self.provider)
    }

    private var snapshot: UsageSnapshot? {
        self.usageStore.snapshots[self.provider]
    }

    private var error: String? {
        self.usageStore.errors[self.provider]
    }

    private var status: ProviderConnectionStatus {
        if let _ = self.snapshot {
            return .connected
        } else if let error = self.error {
            if error.contains("authentication") || error.contains("credentials") || error.contains("session") {
                return .needsSetup
            }
            return .error(error)
        }
        return .notConnected
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 12) {
                // Provider icon
                SettingsProviderIcon(provider: self.provider, size: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.provider.displayName)
                        .font(.headline)
                        .foregroundStyle(self.isEnabled ? .primary : .secondary)

                    Text(self.providerDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Status badge
                self.statusBadge

                // Enable toggle
                Toggle("", isOn: self.enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                self.onToggleExpand()
            }

            // Expanded content
            if self.isExpanded {
                Divider()
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 12) {
                    // Status details
                    self.statusDetails

                    // Setup instructions if needed
                    if case .needsSetup = self.status {
                        self.setupInstructions
                    }

                    // Quick actions
                    self.quickActions
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var providerDescription: String {
        switch self.provider {
        case .claude: return "Claude Code CLI"
        case .codex: return "OpenAI Codex CLI"
        case .cursor: return "Cursor IDE"
        case .gemini: return "Google Gemini CLI"
        case .copilot: return "GitHub Copilot"
        case .antigravity: return "Google Antigravity"
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.enabledProviders.contains(self.provider) },
            set: { enabled in
                if enabled {
                    self.settings.enabledProviders.insert(self.provider)
                } else {
                    self.settings.enabledProviders.remove(self.provider)
                }
                self.settings.saveToDefaults()
            }
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch self.status {
        case .connected:
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Connected")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.1))
            .clipShape(Capsule())

        case .needsSetup:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                Text("Setup Required")
                    .font(.caption)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.1))
            .clipShape(Capsule())

        case .error:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                Text("Error")
                    .font(.caption)
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.1))
            .clipShape(Capsule())

        case .notConnected:
            HStack(spacing: 4) {
                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
                Text("Not Connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var statusDetails: some View {
        if let snapshot = self.snapshot {
            VStack(alignment: .leading, spacing: 8) {
                // Identity info
                if let identity = snapshot.identity {
                    HStack {
                        if let email = identity.email {
                            Label(email, systemImage: "person.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let plan = identity.plan {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(plan)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Usage bars
                if let primary = snapshot.primary {
                    HStack {
                        Text(primary.label ?? "Usage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)

                        SettingsUsageBar(percent: primary.usedPercent)

                        Text("\(Int(primary.usedPercent))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 35, alignment: .trailing)
                    }
                }

                if let secondary = snapshot.secondary {
                    HStack {
                        Text(secondary.label ?? "Quota")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)

                        SettingsUsageBar(percent: secondary.usedPercent)

                        Text("\(Int(secondary.usedPercent))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 35, alignment: .trailing)
                    }
                }

                // Reset time
                if let primary = snapshot.primary, let resetsAt = primary.resetsAt {
                    Text("Resets \(Self.formatRelativeTime(resetsAt))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } else if let error = self.error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup Instructions")
                .font(.caption.bold())
                .foregroundStyle(.primary)

            ForEach(Array(self.setupSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 16, alignment: .trailing)
                    Text(step)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var setupSteps: [String] {
        switch self.provider {
        case .claude:
            return [
                "Install Claude Code CLI: npm install -g @anthropic-ai/claude-code",
                "Authenticate: claude login",
                "Click Refresh to verify connection"
            ]
        case .codex:
            return [
                "Install Codex CLI: npm install -g @openai/codex",
                "Set OPENAI_API_KEY environment variable, or",
                "Authenticate: codex auth login"
            ]
        case .cursor:
            return [
                "Open Chrome, Arc, Brave, or Edge browser",
                "Log in to cursor.com",
                "Click Refresh to import session cookies"
            ]
        case .gemini:
            return [
                "Get API key from aistudio.google.com/app/apikey",
                "Set GEMINI_API_KEY environment variable, or",
                "Create ~/.gemini/config.json with {\"apiKey\": \"your-key\"}"
            ]
        case .copilot:
            return [
                "Install GitHub CLI: brew install gh",
                "Authenticate: gh auth login",
                "Ensure Copilot subscription is active"
            ]
        case .antigravity:
            return [
                "Download Antigravity from antigravity.google",
                "Launch and sign in with your Google account",
                "Click Refresh to detect and fetch usage"
            ]
        }
    }

    @ViewBuilder
    private var quickActions: some View {
        HStack(spacing: 12) {
            // Dashboard link
            if let dashboardURL = ProviderRegistry.descriptor(for: self.provider).metadata.dashboardURL {
                Button {
                    NSWorkspace.shared.open(dashboardURL)
                } label: {
                    Label("Dashboard", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            // Refresh button
            Button {
                Task {
                    await self.usageStore.refresh(provider: self.provider)
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer()

            // Status page link
            if let statusURL = ProviderRegistry.descriptor(for: self.provider).metadata.statusPageURL {
                Button {
                    NSWorkspace.shared.open(statusURL)
                } label: {
                    Label("Status", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Helpers

    private static func formatRelativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Provider Connection Status

private enum ProviderConnectionStatus {
    case connected
    case needsSetup
    case error(String)
    case notConnected
}

// MARK: - Settings Provider Icon

struct SettingsProviderIcon: View {
    let provider: ProviderID
    let size: CGFloat

    var body: some View {
        if let image = self.providerImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: self.size, height: self.size)
                .clipShape(RoundedRectangle(cornerRadius: self.size * 0.2))
        } else {
            // Fallback to system icon
            ZStack {
                RoundedRectangle(cornerRadius: self.size * 0.2)
                    .fill(self.providerColor.opacity(0.15))
                    .frame(width: self.size, height: self.size)

                Image(systemName: self.providerSystemImage)
                    .font(.system(size: self.size * 0.5))
                    .foregroundStyle(self.providerColor)
            }
        }
    }

    private var providerImage: NSImage? {
        let imageName = "logo-\(self.provider.rawValue)"
        // Try to load from bundle resources (SwiftPM uses Bundle.module)
        if let url = Bundle.moduleResources.url(forResource: imageName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // Fallback to main bundle
        if let url = Bundle.main.url(forResource: imageName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    private var providerColor: Color {
        switch self.provider {
        case .claude: return Color(red: 0.85, green: 0.55, blue: 0.35)
        case .codex: return Color(red: 0.0, green: 0.65, blue: 0.52)
        case .cursor: return Color(red: 0.4, green: 0.4, blue: 0.9)
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .copilot: return Color(red: 0.0, green: 0.47, blue: 0.84)
        case .antigravity: return Color(red: 0.376, green: 0.729, blue: 0.494)
        }
    }

    private var providerSystemImage: String {
        switch self.provider {
        case .claude: return "message.fill"
        case .codex: return "terminal.fill"
        case .cursor: return "cursorarrow.rays"
        case .gemini: return "sparkles"
        case .copilot: return "airplane"
        case .antigravity: return "waveform.path.ecg"
        }
    }
}

// MARK: - Settings Usage Bar

struct SettingsUsageBar: View {
    let percent: Double

    private var barColor: Color {
        if self.percent >= 95 {
            return .red
        } else if self.percent >= 80 {
            return .orange
        } else {
            return .green
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))

                Capsule()
                    .fill(self.barColor)
                    .frame(width: max(4, geo.size.width * min(1, self.percent / 100)))
            }
        }
        .frame(height: 6)
    }
}

struct NotificationsPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Quota Warnings Section
                NotificationSection(title: "Quota Warnings", icon: "exclamationmark.triangle.fill", iconColor: .orange) {
                    NotificationToggle(
                        title: "Warn at 80%",
                        subtitle: "Get notified when approaching limits",
                        isOn: self.$settings.notifyAt80
                    )
                    NotificationToggle(
                        title: "Warn at 90%",
                        subtitle: "Critical warning before hitting limits",
                        isOn: self.$settings.notifyAt90
                    )
                    NotificationToggle(
                        title: "Warn at 95%",
                        subtitle: "Final warning before exhaustion",
                        isOn: self.$settings.notifyAt95
                    )
                }

                // Status Notifications Section
                NotificationSection(title: "Status Notifications", icon: "bell.badge.fill", iconColor: .blue) {
                    NotificationToggle(
                        title: "Quota depleted",
                        subtitle: "Alert when quota is fully exhausted",
                        isOn: self.$settings.notifyDepleted
                    )
                    NotificationToggle(
                        title: "Quota restored",
                        subtitle: "Notify when quota resets",
                        isOn: self.$settings.notifyRestored
                    )
                    NotificationToggle(
                        title: "Weekly summary",
                        subtitle: "Get a weekly usage report",
                        isOn: self.$settings.notifyWeeklySummary
                    )
                }

                // System Integration Section
                NotificationSection(title: "System Integration", icon: "moon.fill", iconColor: .purple) {
                    NotificationToggle(
                        title: "Respect Do Not Disturb",
                        subtitle: "Silence notifications when DND is active",
                        isOn: self.$settings.respectDND
                    )
                }
            }
            .padding()
        }
    }
}

struct NotificationSection<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: self.icon)
                    .foregroundStyle(self.iconColor)
                Text(self.title)
                    .font(.headline)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                self.content
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}

struct NotificationToggle: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.body)
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: self.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon - use custom logo
            Group {
                if let logoImage = Self.loadAppLogo() {
                    Image(nsImage: logoImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(LinearGradient(
                                colors: [Color(red: 0.85, green: 0.45, blue: 0.35), Color(red: 0.7, green: 0.35, blue: 0.25)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 100, height: 100)

                        Image(systemName: "building.2.fill")
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
            }

            VStack(spacing: 4) {
                Text("Control Tower")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("AI Usage Monitor")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Version 1.0.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            Spacer()

            // Features
            VStack(alignment: .leading, spacing: 8) {
                FeatureRow(icon: "chart.line.uptrend.xyaxis", text: "Track usage across multiple AI providers")
                FeatureRow(icon: "bell.badge", text: "Smart notifications at custom thresholds")
                FeatureRow(icon: "rectangle.stack", text: "Multi-account support")
                FeatureRow(icon: "clock.arrow.circlepath", text: "Automatic refresh")
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Spacer()

            // Links
            HStack(spacing: 20) {
                Link(destination: URL(string: "https://github.com/krishcdbry/ControlTower")!) {
                    Label("GitHub", systemImage: "link")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Link(destination: URL(string: "https://github.com/krishcdbry/ControlTower/issues")!) {
                    Label("Report Issue", systemImage: "exclamationmark.bubble")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: self.icon)
                .font(.caption)
                .foregroundStyle(.blue)
                .frame(width: 20)

            Text(self.text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - About Pane Extension

extension AboutPane {
    static func loadAppLogo() -> NSImage? {
        // Try to load from bundle resources (SwiftPM uses Bundle.module)
        if let url = Bundle.moduleResources.url(forResource: "logo-controltower", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        // Fallback to main bundle
        if let url = Bundle.main.url(forResource: "logo-controltower", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }
}
