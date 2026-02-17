import Charts
import ControlTowerCore
import SwiftUI

/// Enhanced dashboard view with charts and detailed provider info.
struct EnhancedDashboardView: View {
    @Bindable var usageStore: UsageStore
    @Bindable var settingsStore: SettingsStore
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @State private var selectedProvider: ProviderID?
    @State private var showingAnalytics = false
    @State private var costSnapshot: ClaudeCostScanner.CostSnapshot?
    @State private var isLoadingCost = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 12) {
                    if showingAnalytics {
                        analyticsView
                    } else if let provider = selectedProvider {
                        providerDetailView(provider)
                    } else {
                        providerListView
                    }
                }
                .padding()
            }
            .frame(maxHeight: 400)

            Divider()

            // Footer
            footerView
        }
        .frame(width: 380)
        .background(.regularMaterial)
        .onAppear {
            Task {
                await loadCostData()
            }
        }
    }

    private func loadCostData() async {
        isLoadingCost = true
        costSnapshot = await ClaudeCostScanner.shared.scan()
        isLoadingCost = false
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            if selectedProvider != nil || showingAnalytics {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedProvider = nil
                        showingAnalytics = false
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.plain)
            }

            Text(headerTitle)
                .font(.headline)

            Spacer()

            Button(action: { showingAnalytics.toggle() }) {
                Image(systemName: showingAnalytics ? "chart.bar.fill" : "chart.bar")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help("Analytics")

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.body)
                    .rotationEffect(.degrees(usageStore.isRefreshing ? 360 : 0))
                    .animation(usageStore.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: usageStore.isRefreshing)
            }
            .buttonStyle(.plain)
            .disabled(usageStore.isRefreshing)
            .help("Refresh")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var headerTitle: String {
        if showingAnalytics {
            return "Analytics"
        } else if let provider = selectedProvider {
            return ProviderRegistry.descriptor(for: provider).metadata.displayName
        }
        return "Control Tower"
    }

    // MARK: - Provider List

    private var providerListView: some View {
        VStack(spacing: 8) {
            ForEach(ProviderID.allCases, id: \.self) { provider in
                if settingsStore.enabledProviders.contains(provider) {
                    ProviderRowView(
                        provider: provider,
                        snapshot: usageStore.snapshots[provider],
                        error: usageStore.errors[provider],
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedProvider = provider
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Provider Detail

    @ViewBuilder
    private func providerDetailView(_ provider: ProviderID) -> some View {
        let snapshot = usageStore.snapshots[provider]
        let descriptor = ProviderRegistry.descriptor(for: provider)

        VStack(alignment: .leading, spacing: 16) {
            // Status card
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ProviderIconView(provider: provider, size: 32)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(descriptor.metadata.displayName)
                                .font(.headline)

                            // Plan badge
                            if let identity = snapshot?.identity, let plan = identity.plan {
                                PlanBadge(plan: plan)
                            }
                        }

                        if let identity = snapshot?.identity, let email = identity.email {
                            Text(email)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    if let snapshot {
                        UsagePercentBadge(percent: snapshot.highestUsagePercent)
                    }
                }

                if let snapshot {
                    // Primary usage
                    if let primary = snapshot.primary {
                        UsageDetailRow(
                            label: primary.label ?? "Primary",
                            usedPercent: primary.usedPercent,
                            tokenInfo: primary.tokenUsageString,
                            messageInfo: primary.messageUsageString,
                            resetTime: primary.timeUntilReset()
                        )
                    }

                    // Secondary usage
                    if let secondary = snapshot.secondary {
                        UsageDetailRow(
                            label: secondary.label ?? "Secondary",
                            usedPercent: secondary.usedPercent,
                            tokenInfo: secondary.tokenUsageString,
                            messageInfo: secondary.messageUsageString,
                            resetTime: secondary.timeUntilReset()
                        )
                    }

                    // Tertiary usage
                    if let tertiary = snapshot.tertiary {
                        UsageDetailRow(
                            label: tertiary.label ?? "Tertiary",
                            usedPercent: tertiary.usedPercent,
                            tokenInfo: tertiary.tokenUsageString,
                            messageInfo: tertiary.messageUsageString,
                            resetTime: tertiary.timeUntilReset()
                        )
                    }

                    // Usage pace for Claude
                    if provider == .claude, let secondary = snapshot.secondary {
                        if let pace = UsagePace.weekly(window: secondary) {
                            Divider()
                            UsagePaceRow(pace: pace)
                        }
                    }

                    // Extra usage cost from OAuth
                    if let cost = snapshot.cost {
                        Divider()
                        CostInfoRow(cost: cost)
                    }

                    // JSONL cost data for Claude
                    if provider == .claude, let costData = costSnapshot {
                        Divider()
                        ClaudeCostRow(costSnapshot: costData)
                    }
                } else if let error = usageStore.errors[provider] {
                    // Setup card for providers that need configuration
                    ProviderSetupCard(provider: provider, error: error)
                } else {
                    Text("Loading...")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)

            // Cost chart for Claude
            if provider == .claude {
                if let costData = costSnapshot, !costData.dailyCosts.isEmpty {
                    ClaudeCostChartView(
                        dailyCosts: costData.dailyCosts,
                        period: .week,
                        updatedAt: costData.updatedAt,
                        isLoading: isLoadingCost
                    )
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(10)
                } else if isLoadingCost {
                    // Show loading skeleton while first scan
                    ClaudeCostChartView(
                        dailyCosts: [],
                        period: .week,
                        isLoading: true
                    )
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(10)
                } else {
                    // No data available
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No usage history")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Start using Claude Code to see analytics")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(10)
                }
            } else {
                // Mini chart (placeholder - would need historical data)
                UsageChartView(
                    data: generateMockChartData(for: snapshot),
                    title: "Usage (24h)",
                    color: ProviderUsageData.color(for: provider)
                )
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
            }

            // Actions
            HStack(spacing: 12) {
                if let dashboardURL = descriptor.metadata.dashboardURL {
                    Button("Open Dashboard") {
                        NSWorkspace.shared.open(dashboardURL)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
        }
    }

    // MARK: - Analytics View

    private var analyticsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Provider comparison
            ProvidersComparisonChart(
                data: ProviderID.allCases.compactMap { provider -> ProviderUsageData? in
                    guard settingsStore.enabledProviders.contains(provider),
                          let snapshot = usageStore.snapshots[provider] else {
                        return nil
                    }
                    return ProviderUsageData(provider: provider, usedPercent: snapshot.highestUsagePercent)
                }
            )
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)

            // Summary stats
            SummaryStatsView(usageStore: usageStore, settingsStore: settingsStore)

            // Export buttons
            HStack {
                Button("Export JSON") {
                    // TODO: Export functionality
                }
                .buttonStyle(.bordered)

                Button("Export CSV") {
                    // TODO: Export functionality
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            if let lastRefresh = usageStore.lastRefresh {
                Text("Updated \(lastRefresh, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Settings") {
                onSettings()
            }
            .buttonStyle(.plain)
            .font(.caption)

            Text("•")
                .foregroundStyle(.tertiary)

            Button("Quit") {
                onQuit()
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func generateMockChartData(for snapshot: UsageSnapshot?) -> [ChartDataPoint] {
        // Generate mock data for demo - real implementation would use AnalyticsStore
        let baseValue = snapshot?.highestUsagePercent ?? 50
        return (0..<24).map { i in
            ChartDataPoint(
                date: Date().addingTimeInterval(-Double(i) * 3600),
                value: max(0, min(100, baseValue + Double.random(in: -15...15)))
            )
        }.reversed()
    }
}

// MARK: - Supporting Views

struct ProviderRowView: View {
    let provider: ProviderID
    let snapshot: UsageSnapshot?
    let error: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ProviderIconView(provider: provider, size: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider.displayName)
                            .font(.body.weight(.medium))

                        Spacer()

                        if let snapshot {
                            Text("\(Int(snapshot.highestUsagePercent))%")
                                .font(.title3.weight(.semibold).monospacedDigit())
                                .foregroundStyle(colorForUsage(snapshot.highestUsagePercent))
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if let snapshot {
                        // Primary usage bar with label
                        if let primary = snapshot.primary {
                            HStack(spacing: 6) {
                                Text(primary.label ?? "Primary")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 65, alignment: .leading)
                                    .lineLimit(1)

                                UsageProgressBar(percent: primary.usedPercent)
                                    .frame(maxWidth: 80)

                                Text("\(Int(primary.usedPercent))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }

                        // Secondary usage bar (if present)
                        if let secondary = snapshot.secondary {
                            HStack(spacing: 6) {
                                Text(secondary.label ?? "Secondary")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 65, alignment: .leading)
                                    .lineLimit(1)

                                UsageProgressBar(percent: secondary.usedPercent)
                                    .frame(maxWidth: 80)

                                Text("\(Int(secondary.usedPercent))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }

                        // Tertiary usage bar (for Antigravity with 3 models)
                        if let tertiary = snapshot.tertiary {
                            HStack(spacing: 6) {
                                Text(tertiary.label ?? "Tertiary")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 65, alignment: .leading)
                                    .lineLimit(1)

                                UsageProgressBar(percent: tertiary.usedPercent)
                                    .frame(maxWidth: 80)

                                Text("\(Int(tertiary.usedPercent))%")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, alignment: .trailing)
                            }
                        }
                    } else if error != nil {
                        // Show setup prompt instead of generic error
                        ProviderSetupPrompt(provider: provider, error: error)
                    } else {
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func colorForUsage(_ percent: Double) -> Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        if percent >= 50 { return .yellow }
        return .primary
    }
}

struct UsageProgressBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.2))

                RoundedRectangle(cornerRadius: 2)
                    .fill(colorForPercent(percent))
                    .frame(width: geo.size.width * min(1, percent / 100))
            }
        }
        .frame(height: 4)
    }

    private func colorForPercent(_ percent: Double) -> Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        if percent >= 50 { return .yellow }
        return .blue
    }
}

// MARK: - Provider Setup Prompt

struct ProviderSetupPrompt: View {
    let provider: ProviderID
    let error: String?

    private var setupInfo: ProviderSetupInfo {
        ProviderSetupInfo.forProvider(provider, error: error)
    }

    private var displayError: String {
        // Extract a short, user-friendly message from the error
        guard let error = error else { return setupInfo.hint }

        let lower = error.lowercased()
        if lower.contains("no cursor session") || lower.contains("no session") {
            return "Sign in to cursor.com"
        }
        if lower.contains("not found") || lower.contains("not installed") {
            return "CLI not installed"
        }
        if lower.contains("expired") || lower.contains("invalid token") {
            return "Session expired"
        }
        if lower.contains("unauthorized") || lower.contains("401") {
            return "Re-authentication needed"
        }
        if lower.contains("rate limit") || lower.contains("429") {
            return "Rate limited"
        }
        return setupInfo.hint
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: setupInfo.primaryAction) {
                HStack(spacing: 4) {
                    Image(systemName: setupInfo.icon)
                        .font(.system(size: 9))
                    Text(setupInfo.buttonTitle)
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(setupInfo.buttonColor.opacity(0.15))
                .foregroundStyle(setupInfo.buttonColor)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Text(displayError)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

// MARK: - Provider Setup Card (Detail View)

struct ProviderSetupCard: View {
    let provider: ProviderID
    let error: String

    private var setupInfo: ProviderSetupInfo {
        ProviderSetupInfo.forProvider(provider, error: error)
    }

    private var detailInfo: ProviderSetupDetailInfo {
        ProviderSetupDetailInfo.forProvider(provider, error: error)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "gear.badge.questionmark")
                    .font(.system(size: 16))
                    .foregroundStyle(setupInfo.buttonColor)

                Text("Setup Required")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            // Description
            Text(detailInfo.description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Steps
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(detailInfo.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 16, alignment: .trailing)

                        Text(step)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            // Action buttons
            HStack(spacing: 12) {
                Button(action: setupInfo.primaryAction) {
                    HStack(spacing: 6) {
                        Image(systemName: setupInfo.icon)
                            .font(.system(size: 11))
                        Text(setupInfo.buttonTitle)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(setupInfo.buttonColor)
                    .foregroundStyle(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                if let secondaryAction = detailInfo.secondaryAction {
                    Button(action: secondaryAction.action) {
                        HStack(spacing: 4) {
                            Image(systemName: secondaryAction.icon)
                                .font(.system(size: 10))
                            Text(secondaryAction.title)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }

            // Error details (collapsible)
            DisclosureGroup {
                Text(error)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
            } label: {
                Text("Show error details")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }
}

struct ProviderSetupDetailInfo {
    let description: String
    let steps: [String]
    let secondaryAction: (title: String, icon: String, action: () -> Void)?

    static func forProvider(_ provider: ProviderID, error: String?) -> ProviderSetupDetailInfo {
        let errorLower = error?.lowercased() ?? ""
        let needsInstall = errorLower.contains("not found") ||
                           errorLower.contains("not installed") ||
                           errorLower.contains("not available") ||
                           errorLower.contains("no available fetch strategy")

        // For Cursor, try to extract the browser list from the error
        let cursorBrowsers: String = {
            if let error = error, error.contains("Safari") {
                // Error already contains browser list
                return error
            }
            return "Safari, Chrome, Microsoft Edge, Brave, Arc, Firefox, Vivaldi, or Zen"
        }()

        switch provider {
        case .claude:
            if needsInstall {
                return ProviderSetupDetailInfo(
                    description: "Claude Code CLI needs to be installed to track your usage.",
                    steps: [
                        "Install Claude Code CLI from Anthropic",
                        "Run 'claude' in Terminal to verify",
                        "Sign in with your Anthropic account"
                    ],
                    secondaryAction: ("Documentation", "book", {
                        ProviderSetupInfo.openURL("https://docs.anthropic.com/en/docs/claude-code")
                    })
                )
            }
            return ProviderSetupDetailInfo(
                description: "Sign in to your Claude account to track usage across all your sessions.",
                steps: [
                    "Click 'Sign In' to open Terminal",
                    "Run 'claude login' if prompted",
                    "Complete authentication in browser"
                ],
                secondaryAction: ("Open in Browser", "safari", {
                    ProviderSetupInfo.openURL("https://console.anthropic.com")
                })
            )

        case .codex:
            if needsInstall {
                return ProviderSetupDetailInfo(
                    description: "OpenAI Codex CLI needs to be installed to track your usage.",
                    steps: [
                        "Install Codex CLI: npm install -g @openai/codex",
                        "Run 'codex' in Terminal to verify",
                        "Sign in with your OpenAI account"
                    ],
                    secondaryAction: ("GitHub", "link", {
                        ProviderSetupInfo.openURL("https://github.com/openai/codex")
                    })
                )
            }
            return ProviderSetupDetailInfo(
                description: "Sign in to your OpenAI account to track Codex usage.",
                steps: [
                    "Click 'Sign In' to open Terminal",
                    "Run 'codex auth' if prompted",
                    "Complete authentication in browser"
                ],
                secondaryAction: ("OpenAI Dashboard", "safari", {
                    ProviderSetupInfo.openURL("https://platform.openai.com")
                })
            )

        case .cursor:
            // Use actual error if it contains browser list, otherwise use default
            let description = error?.contains("cursor.com") == true
                ? error!
                : "No Cursor session found. Please log in to cursor.com in \(cursorBrowsers)."

            return ProviderSetupDetailInfo(
                description: description,
                steps: [
                    "Open one of the supported browsers",
                    "Sign in at cursor.com/settings",
                    "Cookies will be imported automatically"
                ],
                secondaryAction: ("Usage Dashboard", "chart.bar", {
                    ProviderSetupInfo.openURL("https://cursor.com/settings")
                })
            )

        case .gemini:
            if needsInstall {
                return ProviderSetupDetailInfo(
                    description: "Gemini CLI needs to be installed to track your usage.",
                    steps: [
                        "Install Gemini CLI from Google",
                        "Run 'gemini' in Terminal to verify",
                        "Sign in with your Google account"
                    ],
                    secondaryAction: ("GitHub", "link", {
                        ProviderSetupInfo.openURL("https://github.com/google-gemini/gemini-cli")
                    })
                )
            }
            return ProviderSetupDetailInfo(
                description: "Sign in with your Google account to track Gemini usage.",
                steps: [
                    "Click 'Sign In' to open Terminal",
                    "Run 'gemini auth' if prompted",
                    "Sign in with Google in browser"
                ],
                secondaryAction: ("AI Studio", "safari", {
                    ProviderSetupInfo.openURL("https://aistudio.google.com")
                })
            )

        case .copilot:
            return ProviderSetupDetailInfo(
                description: "Sign in with GitHub to track your Copilot usage and limits.",
                steps: [
                    "Click 'Sign In' to open GitHub",
                    "Enter the device code shown",
                    "Authorize the application"
                ],
                secondaryAction: ("Copilot Settings", "safari", {
                    ProviderSetupInfo.openURL("https://github.com/settings/copilot")
                })
            )

        case .antigravity:
            return ProviderSetupDetailInfo(
                description: "Launch Antigravity to enable usage tracking.",
                steps: [
                    "Download and install Antigravity from Google",
                    "Launch the application and sign in with Google",
                    "Refresh to detect and fetch usage"
                ],
                secondaryAction: ("Google Antigravity", "safari", {
                    ProviderSetupInfo.openURL("https://antigravity.google/")
                })
            )
        }
    }
}

struct ProviderSetupInfo {
    let buttonTitle: String
    let hint: String
    let icon: String
    let buttonColor: Color
    let primaryAction: () -> Void

    static func forProvider(_ provider: ProviderID, error: String?) -> ProviderSetupInfo {
        let errorLower = error?.lowercased() ?? ""
        let needsInstall = errorLower.contains("not found") ||
                           errorLower.contains("not installed") ||
                           errorLower.contains("not available") ||
                           errorLower.contains("no available fetch strategy")

        switch provider {
        case .claude:
            if needsInstall {
                return ProviderSetupInfo(
                    buttonTitle: "Install CLI",
                    hint: "Claude CLI required",
                    icon: "arrow.down.circle",
                    buttonColor: .orange,
                    primaryAction: { openURL("https://docs.anthropic.com/en/docs/claude-code") }
                )
            }
            return ProviderSetupInfo(
                buttonTitle: "Sign In",
                hint: "Run claude login",
                icon: "terminal",
                buttonColor: .orange,
                primaryAction: { openTerminal(command: "claude") }
            )

        case .codex:
            if needsInstall {
                return ProviderSetupInfo(
                    buttonTitle: "Install CLI",
                    hint: "Codex CLI required",
                    icon: "arrow.down.circle",
                    buttonColor: .purple,
                    primaryAction: { openURL("https://github.com/openai/codex") }
                )
            }
            return ProviderSetupInfo(
                buttonTitle: "Sign In",
                hint: "Run codex login",
                icon: "terminal",
                buttonColor: .purple,
                primaryAction: { openTerminal(command: "codex") }
            )

        case .cursor:
            return ProviderSetupInfo(
                buttonTitle: "Sign In",
                hint: "Log in to cursor.com in browser",
                icon: "safari",
                buttonColor: .green,
                primaryAction: { openURL("https://cursor.com/settings") }
            )

        case .gemini:
            if needsInstall {
                return ProviderSetupInfo(
                    buttonTitle: "Install CLI",
                    hint: "Gemini CLI required",
                    icon: "arrow.down.circle",
                    buttonColor: .blue,
                    primaryAction: { openURL("https://github.com/google-gemini/gemini-cli") }
                )
            }
            return ProviderSetupInfo(
                buttonTitle: "Sign In",
                hint: "Google account",
                icon: "person.circle",
                buttonColor: .blue,
                primaryAction: { openTerminal(command: "gemini") }
            )

        case .copilot:
            return ProviderSetupInfo(
                buttonTitle: "Sign In",
                hint: "GitHub login",
                icon: "person.circle",
                buttonColor: .blue,
                primaryAction: { openURL("https://github.com/login/device") }
            )

        case .antigravity:
            return ProviderSetupInfo(
                buttonTitle: "Get Started",
                hint: "Google Antigravity",
                icon: "safari",
                buttonColor: Color(red: 0.376, green: 0.729, blue: 0.494),
                primaryAction: { openURL("https://antigravity.google/") }
            )
        }
    }

    static func openTerminal(command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    static func openURL(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ProviderIconView: View {
    let provider: ProviderID
    let size: CGFloat

    var body: some View {
        if let image = providerImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            // Fallback to colored circle with letter
            Circle()
                .fill(ProviderUsageData.color(for: provider).gradient)
                .frame(width: size, height: size)
                .overlay {
                    Text(String(provider.displayName.prefix(1)))
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
    }

    private var providerImage: NSImage? {
        let imageName = "logo-\(provider.rawValue)"
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
}

// MARK: - Plan Badge

struct PlanBadge: View {
    let plan: String

    private var badgeColor: Color {
        let lower = plan.lowercased()
        if lower.contains("max") { return .purple }
        if lower.contains("pro") { return .blue }
        if lower.contains("team") { return .orange }
        if lower.contains("enterprise") { return .red }
        return .gray
    }

    private var badgeIcon: String {
        let lower = plan.lowercased()
        if lower.contains("max") { return "bolt.fill" }
        if lower.contains("pro") { return "star.fill" }
        if lower.contains("team") { return "person.3.fill" }
        if lower.contains("enterprise") { return "building.2.fill" }
        return "checkmark.seal.fill"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: badgeIcon)
                .font(.system(size: 8, weight: .bold))

            Text(plan)
                .font(.system(size: 9, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.3)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(badgeColor.gradient)
        }
    }
}

struct UsageMiniBar: View {
    let label: String
    let percent: Double
    let resetTime: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let resetTime {
                    Text("• \(resetTime)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorForPercent(percent))
                        .frame(width: geo.size.width * min(1, percent / 100))
                }
            }
            .frame(width: 80, height: 4)
        }
    }

    private func colorForPercent(_ percent: Double) -> Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        if percent >= 50 { return .yellow }
        return .blue
    }
}

struct UsagePercentBadge: View {
    let percent: Double

    var body: some View {
        Text("\(Int(percent))%")
            .font(.title.weight(.bold).monospacedDigit())
            .foregroundStyle(colorForPercent(percent))
    }

    private func colorForPercent(_ percent: Double) -> Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        if percent >= 50 { return .yellow }
        return .green
    }
}

struct UsageDetailRow: View {
    let label: String
    let usedPercent: Double
    let tokenInfo: String?
    let messageInfo: String?
    let resetTime: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text("\(Int(usedPercent))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(colorForPercent(usedPercent))
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(colorForPercent(usedPercent).gradient)
                        .frame(width: geo.size.width * min(1, usedPercent / 100))
                }
            }
            .frame(height: 6)

            HStack {
                if let tokenInfo {
                    Text(tokenInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let messageInfo {
                    Text(messageInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let resetTime {
                    Text("Resets in \(resetTime)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func colorForPercent(_ percent: Double) -> Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        if percent >= 50 { return .yellow }
        return .blue
    }
}

struct CostInfoRow: View {
    let cost: ProviderCostInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cost")
                    .font(.subheadline.weight(.medium))

                if let daily = cost.dailyCostUSD {
                    Text(String(format: "$%.2f today", daily))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let monthly = cost.monthlyCostUSD {
                Text(String(format: "$%.2f", monthly))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
            }

            if let credits = cost.remainingCredits, let total = cost.totalCredits {
                Text(String(format: "$%.0f / $%.0f", credits, total))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SummaryStatsView: View {
    @Bindable var usageStore: UsageStore
    @Bindable var settingsStore: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                StatBox(
                    title: "Active",
                    value: "\(activeProviders)",
                    subtitle: "providers"
                )

                StatBox(
                    title: "Avg Usage",
                    value: "\(Int(averageUsage))%",
                    subtitle: "across all"
                )

                StatBox(
                    title: "Alerts",
                    value: "\(highUsageCount)",
                    subtitle: "high usage"
                )
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }

    private var activeProviders: Int {
        usageStore.snapshots.count
    }

    private var averageUsage: Double {
        let values = usageStore.snapshots.values.map { $0.highestUsagePercent }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private var highUsageCount: Int {
        usageStore.snapshots.values.filter { $0.highestUsagePercent >= 80 }.count
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Usage Pace Row

struct UsagePaceRow: View {
    let pace: UsagePace

    private var stageColor: Color {
        switch pace.stage {
        case .farAhead: return .red
        case .ahead: return .orange
        case .slightlyAhead: return .yellow
        case .onTrack: return .green
        case .slightlyBehind: return .green
        case .behind: return .blue
        case .farBehind: return .blue
        }
    }

    private var stageIcon: String {
        switch pace.stage {
        case .farAhead, .ahead, .slightlyAhead:
            return "exclamationmark.triangle.fill"
        case .onTrack:
            return "checkmark.circle.fill"
        case .slightlyBehind, .behind, .farBehind:
            return "leaf.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Icon with glow
            ZStack {
                Circle()
                    .fill(stageColor.opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: stageIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(stageColor)
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Weekly Pace")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    // Pace badge
                    Text(pace.paceDescription)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(stageColor.gradient)
                        }
                }

                if let eta = pace.etaDescription {
                    Text(eta)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Visual gauge
            PaceGauge(
                expected: pace.expectedUsedPercent,
                actual: pace.actualUsedPercent,
                color: stageColor
            )
        }
    }
}

// MARK: - Pace Gauge

private struct PaceGauge: View {
    let expected: Double
    let actual: Double
    let color: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // Mini bar comparison
            HStack(spacing: 4) {
                // Expected
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Expected")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: CGFloat(expected / 100) * 40, height: 3)
                }

                // Actual
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Actual")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color.gradient)
                        .frame(width: CGFloat(min(actual, 100) / 100) * 40, height: 3)
                }
            }

            Text("\(Int(actual))% used")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Claude Cost Row (Token-focused)

struct ClaudeCostRow: View {
    let costSnapshot: ClaudeCostScanner.CostSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "number.square.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.blue.opacity(0.8))
                Text("Token Usage")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }

            // Stats cards - tokens primary, cost secondary
            HStack(spacing: 10) {
                // Today
                TokenCostCard(
                    title: "Today",
                    tokens: costSnapshot.todayTokens,
                    cost: costSnapshot.todayCostUSD,
                    accentColor: .blue
                )

                // 7 Days
                TokenCostCard(
                    title: "7 Days",
                    tokens: costSnapshot.last7DaysTokens,
                    cost: costSnapshot.last7DaysCostUSD,
                    accentColor: .purple
                )

                // 30 Days
                TokenCostCard(
                    title: "30 Days",
                    tokens: costSnapshot.last30DaysTokens,
                    cost: costSnapshot.last30DaysCostUSD,
                    accentColor: .orange
                )
            }
        }
    }
}

// MARK: - Token Cost Card (Token-first design)

private struct TokenCostCard: View {
    let title: String
    let tokens: Int
    let cost: Double
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            // Tokens (PRIMARY)
            Text(formatTokens(tokens))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(tokenGradient)

            // Cost (secondary)
            HStack(spacing: 3) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.green.opacity(0.7))
                Text(String(format: "$%.2f", cost))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(accentColor.opacity(0.2), lineWidth: 1)
                }
        }
    }

    private var tokenGradient: LinearGradient {
        LinearGradient(
            colors: [accentColor, accentColor.opacity(0.7)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
