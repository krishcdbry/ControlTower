import Charts
import ControlTowerCore
import SwiftUI

// MARK: - Premium Dashboard View

/// Beautiful CleanMyMac-inspired dashboard with gradient background and glass cards.
struct PremiumDashboardView: View {
    @Bindable var usageStore: UsageStore
    @Bindable var settingsStore: SettingsStore
    var ledgerStore: TokenLedgerStore
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void
    var onClose: () -> Void = {}

    @State private var selectedProvider: ProviderID?
    private var codexCostSnapshot: CodexCostScanner.CostSnapshot? { ledgerStore.codexSnapshot }
    @State private var isLoadingCost = false
    @State private var selectedHeatDay: String?
    @State private var heatDayDetail: LedgerDayDetail?

    private var enabledProviders: [ProviderID] {
        ProviderID.allCases.filter { settingsStore.enabledProviders.contains($0) }
    }

    var body: some View {
        ZStack {
            // Gradient background
            premiumGradient
                .ignoresSafeArea()

            VStack(spacing: 14) {
                // Header
                headerSection
                    .padding(.horizontal, 16)

                // Main content - scrollable
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        if let selected = selectedProvider {
                            // Detail view for selected provider
                            providerDetailSection(selected)
                        } else {
                            // Provider grid
                            providerGridSection
                        }
                    }
                    .padding(.horizontal, 16)
                }

                // Footer
                footerSection
                    .padding(.horizontal, 16)
            }
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 420)
        .frame(maxHeight: 650)
        .onAppear {
            Task { await loadCostData() }
        }
        .onChange(of: selectedProvider) { _, newProvider in
            // Load provider-specific cost data when selected
            Task { await loadProviderCostData(newProvider) }
        }
        .task(id: selectedHeatDay) {
            guard let day = selectedHeatDay else {
                heatDayDetail = nil
                return
            }
            heatDayDetail = await ledgerStore.dayDetail(day)
        }
        .onExitCommand {
            onClose()
        }
    }

    private func loadCostData() async {
        isLoadingCost = true
        defer { isLoadingCost = false }
        await ledgerStore.refreshAndWait()
    }

    private func loadProviderCostData(_ provider: ProviderID?) async {
        guard let provider else { return }
        isLoadingCost = true
        defer { isLoadingCost = false }
        switch provider {
        case .claude, .codex:
            await ledgerStore.refreshAndWait()
        default:
            break
        }
    }

    // MARK: - Premium Gradient (Darker)

    private var premiumGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.06, blue: 0.18), // Very dark purple
                Color(red: 0.10, green: 0.08, blue: 0.22), // Dark purple
                Color(red: 0.08, green: 0.10, blue: 0.20), // Dark purple-blue
                Color(red: 0.06, green: 0.08, blue: 0.18)  // Very dark blue
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("AI Usage:")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(overallStatusText)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(overallStatusColor)
                }

                Text(statusSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            // Animated icon
            ZStack {
                Circle()
                    .fill(overallStatusColor.opacity(0.2))
                    .frame(width: 50, height: 50)

                Image(systemName: overallStatusIcon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(overallStatusColor)
            }
        }
    }

    private var measuredUsage: Double? {
        enabledProviders.compactMap { provider -> Double? in
            guard let snapshot = usageStore.snapshots[provider], snapshot.hasUsageWindows else { return nil }
            return snapshot.highestUsagePercent
        }.max()
    }

    private var overallStatusText: String {
        guard let maxUsage = measuredUsage else { return "Unavailable" }
        if maxUsage >= 95 { return "Critical" }
        if maxUsage >= 80 { return "High" }
        if maxUsage >= 50 { return "Moderate" }
        return "Healthy"
    }

    private var overallStatusColor: Color {
        guard let maxUsage = measuredUsage else { return .gray }
        if maxUsage >= 95 { return .red }
        if maxUsage >= 80 { return .orange }
        if maxUsage >= 50 { return .yellow }
        return Color(red: 0.4, green: 0.9, blue: 0.5) // Bright green
    }

    private var overallStatusIcon: String {
        guard let maxUsage = measuredUsage else { return "questionmark.circle" }
        if maxUsage >= 95 { return "exclamationmark.triangle.fill" }
        if maxUsage >= 80 { return "exclamationmark.circle.fill" }
        if maxUsage >= 50 { return "gauge.with.dots.needle.50percent" }
        return "checkmark.shield.fill"
    }

    private var statusSubtitle: String {
        let activeCount = usageStore.snapshots.count
        let totalCount = enabledProviders.count
        if usageStore.isRefreshing {
            return "Refreshing..."
        }
        return "\(activeCount)/\(totalCount) providers active"
    }

    // MARK: - Provider Grid Section

    private var providerGridSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ], spacing: 10) {
            ForEach(enabledProviders, id: \.self) { provider in
                GlassProviderCard(
                    provider: provider,
                    snapshot: usageStore.snapshots[provider],
                    error: usageStore.errors[provider],
                    onTap: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selectedProvider = provider
                        }
                    }
                )
            }
        }
    }

    // MARK: - Provider Detail Section

    @ViewBuilder
    private func providerDetailSection(_ provider: ProviderID) -> some View {
        let snapshot = usageStore.snapshots[provider]
        let pace: UsagePace? = {
            if let secondary = snapshot?.secondary {
                return UsagePace.weekly(window: secondary)
            }
            return nil
        }()

        VStack(alignment: .leading, spacing: 12) {
            // Back button
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedProvider = nil
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back to Overview")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)

            // Main detail card with pace integrated
            GlassDetailCard(
                provider: provider,
                snapshot: snapshot,
                error: usageStore.errors[provider],
                pace: pace
            )

            // Token Usage Section
            if provider == .claude {
                if let ledger = ledgerStore.snapshot {
                    // Live 5-hour block (burn rate, projection, reset countdown).
                    if let block = ledger.currentBlock {
                        GlassLiveBlockCard(block: block)
                    }

                    SimpleTokenSummary(
                        todayTokens: ledger.today.totalTokens,
                        todayCost: ledger.today.costUSD,
                        last7DaysTokens: ledger.last7Days.totalTokens,
                        last7DaysCost: ledger.last7Days.costUSD,
                        last30DaysTokens: ledger.last30Days.totalTokens,
                        last30DaysCost: ledger.last30Days.costUSD
                    )

                    // Per-app split: Claude Code vs Desktop/Cowork, plus top projects.
                    if !ledger.bySource.isEmpty {
                        GlassSourceBreakdownCard(
                            bySource: ledger.bySource,
                            topProjects: Array(ledger.byProject.prefix(3))
                        )
                    }

                    // Activity heatmap with per-day drill-down.
                    if !ledger.dailyActivity.isEmpty {
                        GlassHeatmapCard(
                            activity: ledger.dailyActivity,
                            selectedDay: $selectedHeatDay
                        )
                        if let day = selectedHeatDay {
                            if let detail = heatDayDetail {
                                GlassDayDetailCard(detail: detail) {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        selectedHeatDay = nil
                                    }
                                }
                            } else {
                                GlassDayDetailLoading(date: day)
                            }
                        }
                    }

                    if ledger.stats.isInitialScan {
                        Text("Indexed \(ledger.stats.filesParsed) transcripts (\(ledger.stats.entriesAdded) messages)")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                } else if ledgerStore.isLoading || isLoadingCost {
                    TokenLoadingPlaceholder()
                }
            } else if provider == .codex {
                if let costData = codexCostSnapshot {
                    SimpleTokenSummary(
                        todayTokens: costData.todayTokens,
                        todayCost: costData.todayCostUSD,
                        last7DaysTokens: costData.last7DaysTokens,
                        last7DaysCost: costData.last7DaysCostUSD,
                        last30DaysTokens: costData.last30DaysTokens,
                        last30DaysCost: costData.last30DaysCostUSD
                    )
                    Text(costData.last30DaysCostUSD == nil
                         ? "Token totals include models without known prices. Cost is unavailable for those periods."
                         : "Estimated API cost at standard base rates. Subscription charges and pricing modifiers are excluded.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                } else if isLoadingCost {
                    TokenLoadingPlaceholder()
                }
            }

            // Cost Chart
            if provider == .claude {
                if let ledger = ledgerStore.snapshot, !ledger.days.isEmpty {
                    GlassCostChartCard(
                        dailyCosts: ledger.days.map { .init(date: $0.date, totalTokens: $0.totals.totalTokens, costUSD: $0.totals.costUSD) },
                        updatedAt: ledger.generatedAt
                    )
                } else if ledgerStore.isLoading || isLoadingCost {
                    ChartLoadingPlaceholder()
                }
            } else if provider == .codex {
                if let costData = codexCostSnapshot, !costData.dailyCosts.isEmpty, costData.last30DaysCostUSD != nil {
                    GlassCostChartCard(
                        dailyCosts: costData.dailyCosts.compactMap { day in
                            day.costUSD.map { .init(date: day.date, totalTokens: day.totalTokens, costUSD: $0) }
                        },
                        updatedAt: costData.updatedAt
                    )
                } else if isLoadingCost {
                    ChartLoadingPlaceholder()
                }
            }

            // Dashboard link
            if let dashboardURL = ProviderRegistry.descriptor(for: provider).metadata.dashboardURL {
                Button(action: { NSWorkspace.shared.open(dashboardURL) }) {
                    HStack {
                        Image(systemName: "arrow.up.right.square.fill")
                            .font(.system(size: 14))
                        Text("Open \(provider.displayName) Dashboard")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.cyan.opacity(0.1))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.cyan.opacity(0.3), lineWidth: 1)
                            }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Simple Token Summary (compact single row)

    struct SimpleTokenSummary: View {
        let todayTokens: Int
        let todayCost: Double?
        let last7DaysTokens: Int
        let last7DaysCost: Double?
        let last30DaysTokens: Int
        let last30DaysCost: Double?

        var body: some View {
            HStack(spacing: 20) {
                tokenColumn("Today", tokens: todayTokens, cost: todayCost)

                Divider()
                    .frame(height: 30)
                    .overlay(Color.white.opacity(0.1))

                tokenColumn("7 Days", tokens: last7DaysTokens, cost: last7DaysCost)

                Divider()
                    .frame(height: 30)
                    .overlay(Color.white.opacity(0.1))

                tokenColumn("30 Days", tokens: last30DaysTokens, cost: last30DaysCost)
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.08, green: 0.06, blue: 0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }
            }
        }

        private func tokenColumn(_ title: String, tokens: Int, cost: Double?) -> some View {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

                Text(formatTokens(tokens))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(cost.map { String(format: "$%.2f", $0) } ?? "Price unavailable")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            }
            .frame(maxWidth: .infinity)
        }

        private func formatTokens(_ count: Int) -> String {
            if count >= 1_000_000_000 {
                return String(format: "%.2fB", Double(count) / 1_000_000_000)
            } else if count >= 1_000_000 {
                return String(format: "%.1fM", Double(count) / 1_000_000)
            } else if count >= 1_000 {
                return String(format: "%.0fK", Double(count) / 1_000)
            }
            return "\(count)"
        }
    }

    // MARK: - Loading Placeholders

    struct TokenLoadingPlaceholder: View {
        var body: some View {
            HStack(spacing: 20) {
                loadingColumn("Today")
                Divider().frame(height: 30).overlay(Color.white.opacity(0.1))
                loadingColumn("7 Days")
                Divider().frame(height: 30).overlay(Color.white.opacity(0.1))
                loadingColumn("30 Days")
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.08, green: 0.06, blue: 0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }
            }
        }

        private func loadingColumn(_ title: String) -> some View {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.1))
                    .frame(width: 50, height: 18)

                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.08))
                    .frame(width: 40, height: 12)
            }
            .frame(maxWidth: .infinity)
        }
    }

    struct ChartLoadingPlaceholder: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green.opacity(0.5))

                    Text("Usage History (7 Days)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.white.opacity(0.5))
                }

                // Placeholder bars
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<7, id: \.self) { i in
                        VStack {
                            Spacer()
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white.opacity(0.1))
                                .frame(height: CGFloat([40, 60, 35, 70, 50, 45, 55][i]))
                        }
                    }
                }
                .frame(height: 100)

                Text("Calculating token usage...")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.10, green: 0.08, blue: 0.22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
            }
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack(spacing: 16) {
            // App icon + name
            HStack(spacing: 8) {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))

                Text("Control Tower")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            // Refresh button
            Button(action: onRefresh) {
                Image(systemName: usageStore.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .rotationEffect(.degrees(usageStore.isRefreshing ? 360 : 0))
                    .animation(usageStore.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: usageStore.isRefreshing)
            }
            .buttonStyle(GlassButtonStyle())
            .disabled(usageStore.isRefreshing)

            // Settings button
            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(GlassButtonStyle())
        }
    }
}

// MARK: - Glass Provider Card

struct GlassProviderCard: View {
    let provider: ProviderID
    let snapshot: UsageSnapshot?
    let error: String?
    let onTap: () -> Void

    @State private var isHovered = false

    private var usagePercent: Double {
        snapshot?.highestUsagePercent ?? 0
    }

    private var usageColor: Color {
        if usagePercent >= 95 { return .red }
        if usagePercent >= 80 { return .orange }
        if usagePercent >= 50 { return .yellow }
        return Color(red: 0.3, green: 0.85, blue: 0.5) // Cyan-green
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                // Header row
                HStack {
                    GlassProviderIcon(provider: provider, size: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if let snapshot, let primary = snapshot.primary {
                            Text(primary.label ?? "Usage")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                        } else if error != nil {
                            Text("Setup required")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange.opacity(0.8))
                        }
                    }

                    Spacer()
                }

                Spacer(minLength: 4)

                // Usage display
                if let snapshot, snapshot.hasUsageWindows {
                    HStack(alignment: .bottom, spacing: 4) {
                        Text("\(Int(usagePercent))")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(usageColor)

                        Text("%")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(usageColor.opacity(0.7))
                            .padding(.bottom, 4)

                        Spacer()
                    }

                    // Full width progress bar using ProgressView style
                    ProgressView(value: usagePercent, total: 100)
                        .progressViewStyle(GlassProgressStyle(color: usageColor))
                } else if snapshot != nil {
                    Text("Usage unavailable")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if error != nil {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.cyan)
                        Text("Tap to setup")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.cyan)
                    }
                    Spacer()
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .tint(.white.opacity(0.8))
                            Text("Fetching...")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        // Placeholder progress bar
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(0.1))
                            .frame(height: 6)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(minHeight: 115)
            .background {
                ZStack {
                    // Solid dark background
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(red: 0.12, green: 0.10, blue: 0.25))

                    // Subtle gradient overlay
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(isHovered ? 0.08 : 0.04),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Border
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            Color.white.opacity(isHovered ? 0.25 : 0.12),
                            lineWidth: 1
                        )
                }
            }
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Glass Provider Icon

struct GlassProviderIcon: View {
    let provider: ProviderID
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(providerColor.opacity(0.3))

            Circle()
                .stroke(providerColor.opacity(0.5), lineWidth: 1)

            // Try to load image, fallback to letter
            if let image = loadProviderImage() {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.65, height: size * 0.65)
            } else {
                Text(String(provider.displayName.prefix(1)))
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var providerColor: Color {
        switch provider {
        case .claude: return .orange
        case .codex: return .purple
        case .cursor: return .green
        case .gemini: return .blue
        case .copilot: return .cyan
        case .antigravity: return Color(red: 0.3, green: 0.7, blue: 0.5)
        }
    }

    private func loadProviderImage() -> NSImage? {
        let imageName = "logo-\(provider.rawValue)"
        if let url = Bundle.moduleResources.url(forResource: imageName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: imageName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }
}

// MARK: - Glass Detail Card

struct GlassDetailCard: View {
    let provider: ProviderID
    let snapshot: UsageSnapshot?
    let error: String?
    var pace: UsagePace? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Provider header
            HStack(spacing: 12) {
                GlassProviderIcon(provider: provider, size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(provider.displayName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)

                        if let identity = snapshot?.identity, let plan = identity.plan {
                            GlassPlanBadge(plan: plan)
                        }
                    }

                    if let identity = snapshot?.identity, let email = identity.email {
                        Text(email)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                Spacer()

                if let snapshot, snapshot.hasUsageWindows {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(snapshot.highestUsagePercent))%")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(usageColor(snapshot.highestUsagePercent))

                        Text("used")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }

            if let snapshot {
                if !snapshot.hasUsageWindows {
                    Text("Subscription usage is unavailable. Local token tracking is still shown below.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                // Usage bars - clean list, no boxes
                VStack(spacing: 16) {
                    if let primary = snapshot.primary {
                        CleanUsageBar(
                            label: primary.label ?? "Session",
                            percent: primary.usedPercent,
                            resetTime: primary.timeUntilReset()
                        )
                    }

                    if let secondary = snapshot.secondary {
                        CleanUsageBar(
                            label: secondary.label ?? "Weekly",
                            percent: secondary.usedPercent,
                            resetTime: secondary.timeUntilReset(),
                            pace: pace
                        )
                    }

                    if let tertiary = snapshot.tertiary {
                        CleanUsageBar(
                            label: tertiary.label ?? "Sonnet",
                            percent: tertiary.usedPercent,
                            resetTime: tertiary.timeUntilReset()
                        )
                    }
                }

                // Cost info if available
                if let cost = snapshot.cost {
                    CleanCostRow(cost: cost)
                }
            } else if let error {
                // Setup instructions
                GlassSetupCard(provider: provider, error: error)
            } else {
                // Loading state
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white)
                    Text("Fetching usage data...")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
        .padding(20)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(red: 0.10, green: 0.08, blue: 0.22))

                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
    }

    private func usageColor(_ percent: Double) -> Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        if percent >= 50 { return .yellow }
        return Color(red: 0.4, green: 0.9, blue: 0.5)
    }
}

// MARK: - Clean Usage Bar

struct CleanUsageBar: View {
    let label: String
    let percent: Double
    let resetTime: String?
    var pace: UsagePace? = nil

    private var usageColor: Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        if percent >= 50 { return .yellow }
        return Color(red: 0.4, green: 0.9, blue: 0.5)
    }

    private var remainingPercent: Int {
        max(0, 100 - Int(percent))
    }

    // Reserve percent (only when in reserve, i.e., delta is negative)
    private var reservePercent: Int? {
        guard let pace, pace.deltaPercent < -3 else { return nil }
        return Int(abs(pace.deltaPercent).rounded())
    }

    // Expected usage marker position (0-1)
    private var expectedPosition: Double? {
        guard let pace else { return nil }
        return min(1, pace.expectedUsedPercent / 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label row: name on left, percentage on right
            HStack {
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(Int(percent))%")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(usageColor)
            }

            // Progress bar - full width with expected marker
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.15))

                    // Progress fill
                    RoundedRectangle(cornerRadius: 4)
                        .fill(usageColor.gradient)
                        .frame(width: geo.size.width * min(1, percent / 100))

                    // Expected usage marker if pace is available
                    if let expected = expectedPosition {
                        Rectangle()
                            .fill(.white.opacity(0.8))
                            .frame(width: 2, height: 12)
                            .offset(x: geo.size.width * expected - 1)
                    }
                }
            }
            .frame(height: 8)

            // Info row: left side shows remaining and reserve, right shows reset time
            HStack {
                Text("\(remainingPercent)% left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                // Reserve info inline
                if let reserve = reservePercent {
                    Text("•")
                        .foregroundStyle(.white.opacity(0.3))
                    Text("\(reserve)% in reserve")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.cyan.opacity(0.9))
                }

                Spacer()

                if let resetTime {
                    Text("Resets in \(resetTime)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            // ETA description on separate line if pace available and in reserve
            if let pace, let etaDesc = pace.etaDescription, reservePercent != nil {
                Text(etaDesc)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

// MARK: - Clean Cost Row (simpler, no heavy box)

struct CleanCostRow: View {
    let cost: ProviderCostInfo

    var body: some View {
        HStack {
            Text("Cost")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            if let monthly = cost.monthlyCostUSD {
                Text(String(format: "$%.2f", monthly))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
            }

            if let credits = cost.remainingCredits, let total = cost.totalCredits {
                Text(String(format: "$%.0f / $%.0f", credits, total))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.green.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.green.opacity(0.2), lineWidth: 1)
                }
        }
    }
}

// MARK: - Glass Cost Info Row

struct GlassCostInfoRow: View {
    let cost: ProviderCostInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cost")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))

                if let daily = cost.dailyCostUSD {
                    Text(String(format: "$%.2f today", daily))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            Spacer()

            if let monthly = cost.monthlyCostUSD {
                Text(String(format: "$%.2f", monthly))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
            }

            if let credits = cost.remainingCredits, let total = cost.totalCredits {
                Text(String(format: "$%.0f / $%.0f", credits, total))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.green.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.green.opacity(0.2), lineWidth: 1)
                }
        }
    }
}

// MARK: - Glass Usage Row

struct GlassUsageRow: View {
    let label: String
    let percent: Double
    let resetTime: String?
    let tokenInfo: String?
    var messageInfo: String? = nil

    private var usageColor: Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        if percent >= 50 { return .yellow }
        return Color(red: 0.3, green: 0.85, blue: 0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(Int(percent))%")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(usageColor)
            }

            // Progress bar - full width
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.15))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [usageColor, usageColor.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * min(1, percent / 100))
                }
            }
            .frame(height: 8)

            // Info row
            HStack {
                if let tokenInfo {
                    Text(tokenInfo)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }

                if let messageInfo {
                    Text("•")
                        .foregroundStyle(.white.opacity(0.3))
                    Text(messageInfo)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                if let resetTime {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(resetTime)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.08, green: 0.06, blue: 0.18))
        }
    }
}

// MARK: - Glass Plan Badge

struct GlassPlanBadge: View {
    let plan: String

    private var badgeColor: Color {
        let lower = plan.lowercased()
        if lower.contains("max") { return .purple }
        if lower.contains("pro") { return .cyan }
        if lower.contains("team") { return .orange }
        return .blue
    }

    var body: some View {
        Text(plan.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(badgeColor.gradient)
            }
    }
}

// MARK: - Glass Setup Card

struct GlassSetupCard: View {
    let provider: ProviderID
    let error: String

    private var setupInfo: (title: String, steps: [String], url: String) {
        switch provider {
        case .claude:
            return ("Sign in to Claude", ["Run 'claude' in Terminal", "Complete browser authentication"], "https://console.anthropic.com")
        case .codex:
            return ("Sign in to Codex", ["Sign in to Codex Desktop with ChatGPT", "Or run 'codex login' in Terminal"], "https://chatgpt.com/codex")
        case .cursor:
            return ("Sign in to Cursor", ["Open cursor.com in browser", "Sign in to your account"], "https://cursor.com/settings")
        case .gemini:
            return ("Sign in to Gemini", ["Run 'gemini' in Terminal", "Sign in with Google"], "https://aistudio.google.com")
        case .copilot:
            return ("Sign in to Copilot", ["Run 'gh auth login'", "Authorize with GitHub"], "https://github.com/settings/copilot")
        case .antigravity:
            return ("Launch Antigravity", ["Download from Google", "Sign in with Google account"], "https://antigravity.google/")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.cyan)

                Text(setupInfo.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            ForEach(Array(setupInfo.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(.cyan.opacity(0.2)))

                    Text(step)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Button(action: { NSWorkspace.shared.open(URL(string: setupInfo.url)!) }) {
                HStack {
                    Text("Get Started")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(.cyan.gradient)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.cyan.opacity(0.2), lineWidth: 1)
                }
        }
    }
}

// MARK: - Glass Token Usage Card

struct GlassTokenUsageCard: View {
    let costSnapshot: ClaudeCostScanner.CostSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "number.square.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)

                Text("Token Usage")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()
            }

            // Token stats in 3 columns
            HStack(spacing: 10) {
                GlassTokenStatBox(
                    title: "Today",
                    tokens: costSnapshot.todayTokens,
                    cost: costSnapshot.todayCostUSD,
                    color: .blue
                )

                GlassTokenStatBox(
                    title: "7 Days",
                    tokens: costSnapshot.last7DaysTokens,
                    cost: costSnapshot.last7DaysCostUSD,
                    color: .purple
                )

                GlassTokenStatBox(
                    title: "30 Days",
                    tokens: costSnapshot.last30DaysTokens,
                    cost: costSnapshot.last30DaysCostUSD,
                    color: .orange
                )
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.10, green: 0.08, blue: 0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
    }
}

struct GlassTokenStatBox: View {
    let title: String
    let tokens: Int
    let cost: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .tracking(0.5)

            Text(formatTokens(tokens))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)

            HStack(spacing: 3) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green.opacity(0.8))
                Text(String(format: "$%.2f", cost))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.2), lineWidth: 1)
                }
        }
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

// MARK: - Generic Daily Cost for Chart

struct ChartDailyCost: Identifiable {
    let id = UUID()
    let date: String
    let totalTokens: Int
    let costUSD: Double

    init(date: String, totalTokens: Int, costUSD: Double) {
        self.date = date
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

// MARK: - Glass Cost Chart Card

struct GlassCostChartCard: View {
    let dailyCosts: [ChartDailyCost]
    let updatedAt: Date?

    private var recentCosts: [ChartDailyCost] {
        Array(dailyCosts.suffix(7))
    }

    private var totalTokens: Int {
        recentCosts.reduce(0) { $0 + $1.totalTokens }
    }

    private var totalCost: Double {
        recentCosts.reduce(0.0) { $0 + $1.costUSD }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chartHeader
            chartContent
            chartSummary
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.10, green: 0.08, blue: 0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
    }

    private var chartHeader: some View {
        HStack {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)

            Text("Usage History (7 Days)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            if let updated = updatedAt {
                Text(updated, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var chartContent: some View {
        Chart(recentCosts, id: \.date) { item in
            BarMark(
                x: .value("Date", formatDayLabel(item.date)),
                y: .value("Tokens", item.totalTokens)
            )
            .foregroundStyle(.green.gradient)
            .cornerRadius(4)
            .annotation(position: .top, spacing: 4) {
                if item.totalTokens > 0 {
                    Text(formatChartTokens(item.totalTokens))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 130)
    }

    private func formatDayLabel(_ dateString: String) -> String {
        // dateString is "YYYY-MM-DD"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE"
        return dayFormatter.string(from: date)
    }

    private var chartSummary: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total Tokens")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Text(formatChartTokens(totalTokens))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Est. Cost")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Text(String(format: "$%.2f", totalCost))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.green)
            }
        }
    }

    private func formatChartTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.2fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Glass Usage Pace Card

struct GlassUsagePaceCard: View {
    let pace: UsagePace

    private var stageColor: Color {
        switch pace.stage {
        case .farAhead: return .red
        case .ahead: return .orange
        case .slightlyAhead: return .yellow
        case .onTrack: return Color(red: 0.3, green: 0.85, blue: 0.5)
        case .slightlyBehind: return .green
        case .behind: return .blue
        case .farBehind: return .cyan
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
        HStack(spacing: 14) {
            // Icon
            ZStack {
                Circle()
                    .fill(stageColor.opacity(0.2))
                    .frame(width: 44, height: 44)

                Image(systemName: stageIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(stageColor)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Weekly Pace")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(pace.paceDescription)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(stageColor.gradient))
                }

                if let eta = pace.etaDescription {
                    Text(eta)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()

            // Visual comparison
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Expected")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.3))
                        .frame(width: 40 * pace.expectedUsedPercent / 100, height: 4)
                }

                HStack(spacing: 4) {
                    Text("Actual")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(stageColor.gradient)
                        .frame(width: min(40, 40 * pace.actualUsedPercent / 100), height: 4)
                }

                Text("\(Int(pace.actualUsedPercent))% used")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.10, green: 0.08, blue: 0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(stageColor.opacity(0.3), lineWidth: 1)
                }
        }
    }
}

// MARK: - Glass Button Style

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 32, height: 32)
            .background {
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? 0.15 : 0.08))
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

// MARK: - Glass Progress Style

struct GlassProgressStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.white.opacity(0.15))

                RoundedRectangle(cornerRadius: 3)
                    .fill(color.gradient)
                    .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Live 5h Block Card

/// Shows the active 5-hour rate-limit block: burn rate, cost pace, and reset
/// countdown. Re-renders on a timeline so the countdown stays current, and
/// picks up new token data live as the ledger ingests transcript writes.
struct GlassLiveBlockCard: View {
    let block: LedgerBlock

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(.orange.opacity(0.2))
                            .frame(width: 28, height: 28)
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Current 5h Block")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Started \(Self.timeFormatter.string(from: block.start))")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(block.remainingDescription(at: now))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                        Text("until reset")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                // Elapsed-time progress across the block.
                GeometryReader { geometry in
                    let progress = min(1, max(0, now.timeIntervalSince(block.start) / block.end.timeIntervalSince(block.start)))
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white.opacity(0.1))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [.orange, .yellow],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 6)

                HStack(spacing: 16) {
                    blockStat("Tokens", value: Self.formatTokens(block.totals.totalTokens))
                    divider
                    blockStat("Cost", value: String(format: "$%.2f", block.totals.costUSD))
                    divider
                    blockStat("Burn", value: "\(Self.formatTokens(Int(block.burnRate(at: now))))/min")
                    divider
                    blockStat("Messages", value: "\(block.totals.entryCount)")
                }
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(red: 0.10, green: 0.08, blue: 0.22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.orange.opacity(0.25), lineWidth: 1)
                    }
            }
        }
    }

    private var divider: some View {
        Divider()
            .frame(height: 24)
            .overlay(Color.white.opacity(0.1))
    }

    private func blockStat(_ title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }

    private static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 { return String(format: "%.2fB", Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - Source Breakdown Card

/// 30-day split of where tokens go: Claude Code vs Claude Desktop / Cowork,
/// plus the heaviest projects.
struct GlassSourceBreakdownCard: View {
    let bySource: [UsageSource: TokenTotals]
    let topProjects: [LedgerProjectUsage]

    private var sortedSources: [(source: UsageSource, totals: TokenTotals)] {
        bySource
            .map { (source: $0.key, totals: $0.value) }
            .sorted { $0.totals.costUSD > $1.totals.costUSD }
    }

    private var totalCost: Double {
        max(0.01, bySource.values.reduce(0) { $0 + $1.costUSD })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.cyan)
                Text("By App (30 Days)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
            }

            VStack(spacing: 10) {
                ForEach(sortedSources, id: \.source) { item in
                    sourceRow(item.source, totals: item.totals)
                }
            }

            if !topProjects.isEmpty {
                Divider()
                    .overlay(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 6) {
                    Text("TOP PROJECTS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))

                    ForEach(topProjects, id: \.path) { project in
                        HStack {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.35))
                            Text(project.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                            Spacer()
                            Text(Self.formatTokens(project.totals.totalTokens))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                            Text(String(format: "$%.0f", project.totals.costUSD))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.green.opacity(0.9))
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.10, green: 0.08, blue: 0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
    }

    private func sourceRow(_ source: UsageSource, totals: TokenTotals) -> some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: source == .claudeDesktop ? "macwindow" : "terminal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(self.color(for: source))
                Text(source.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(Self.formatTokens(totals.totalTokens))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Text(String(format: "$%.2f", totals.costUSD))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(width: 62, alignment: .trailing)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(self.color(for: source))
                        .frame(width: geometry.size.width * (totals.costUSD / totalCost))
                }
            }
            .frame(height: 4)
        }
    }

    private func color(for source: UsageSource) -> Color {
        switch source {
        case .claudeDesktop: .purple
        case .claudeCode: .cyan
        case .probe: .gray
        }
    }

    private static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 { return String(format: "%.2fB", Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

// MARK: - Activity Heatmap Card

/// GitHub-style activity heatmap: ~6 months of daily usage in week columns.
/// Tapping a day with activity opens the drill-down panel.
struct GlassHeatmapCard: View {
    let activity: [LedgerActivityDay]
    @Binding var selectedDay: String?

    private static let weekCount = 25
    private static let cellSize: CGFloat = 10
    private static let cellGap: CGFloat = 3

    private struct HeatCell: Identifiable {
        let id: String // day key
        let date: Date
        let tokens: Int
        let level: Int // 0-4
        let isFuture: Bool
    }

    private struct WeekColumn: Identifiable {
        let id: Int
        let monthLabel: String?
        let cells: [HeatCell]
    }

    private var tokensByDay: [String: Int] {
        Dictionary(uniqueKeysWithValues: activity.map { ($0.date, $0.totalTokens) })
    }

    /// Quartile thresholds over non-zero days drive the color levels.
    private var thresholds: [Int] {
        let values = activity.map(\.totalTokens).filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return [1, 2, 3, 4] }
        func quantile(_ q: Double) -> Int {
            values[min(values.count - 1, Int(Double(values.count) * q))]
        }
        return [max(1, quantile(0.25)), quantile(0.5), quantile(0.75), quantile(0.92)]
    }

    private var weeks: [WeekColumn] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // weeks start Monday
        let today = calendar.startOfDay(for: Date())
        guard let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start else { return [] }

        let byDay = self.tokensByDay
        let levels = self.thresholds
        var columns: [WeekColumn] = []
        var previousMonth = -1

        for weekIndex in stride(from: Self.weekCount - 1, through: 0, by: -1) {
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: -weekIndex, to: currentWeekStart) else { continue }

            var cells: [HeatCell] = []
            for dayOffset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { continue }
                let key = TokenLedger.dayKey(for: date, calendar: calendar)
                let tokens = byDay[key] ?? 0
                let level: Int = {
                    guard tokens > 0 else { return 0 }
                    if tokens >= levels[3] { return 4 }
                    if tokens >= levels[2] { return 3 }
                    if tokens >= levels[1] { return 2 }
                    return 1
                }()
                cells.append(HeatCell(id: key, date: date, tokens: tokens, level: level, isFuture: date > today))
            }

            let month = calendar.component(.month, from: weekStart)
            var label: String?
            if month != previousMonth {
                label = Self.monthFormatter.string(from: weekStart)
                previousMonth = month
            }
            columns.append(WeekColumn(id: columns.count, monthLabel: label, cells: cells))
        }
        return columns
    }

    var body: some View {
        let columns = self.weeks
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 13))
                    .foregroundStyle(.purple)
                Text("Activity")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Text("6 months")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                legend
            }

            HStack(alignment: .top, spacing: 6) {
                // Weekday gutter
                VStack(alignment: .trailing, spacing: Self.cellGap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(row == 0 ? "Mon" : row == 2 ? "Wed" : row == 4 ? "Fri" : "")
                            .font(.system(size: 7.5))
                            .foregroundStyle(.white.opacity(0.35))
                            .frame(width: 22, height: Self.cellSize, alignment: .trailing)
                    }
                }
                .padding(.top, 13)

                VStack(alignment: .leading, spacing: 3) {
                    // Month labels positioned over their columns.
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(height: 10)
                        ForEach(columns) { week in
                            if let label = week.monthLabel {
                                Text(label)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .fixedSize()
                                    .offset(x: CGFloat(week.id) * (Self.cellSize + Self.cellGap))
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: Self.cellGap) {
                        ForEach(columns) { week in
                            VStack(spacing: Self.cellGap) {
                                ForEach(week.cells) { cell in
                                    heatCell(cell)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.10, green: 0.08, blue: 0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private func heatCell(_ cell: HeatCell) -> some View {
        let isSelected = selectedDay == cell.id
        if cell.isFuture {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.clear)
                .frame(width: Self.cellSize, height: Self.cellSize)
        } else {
            Button {
                guard cell.tokens > 0 else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    selectedDay = isSelected ? nil : cell.id
                }
            } label: {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Self.color(for: cell.level))
                    .frame(width: Self.cellSize, height: Self.cellSize)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 2.5)
                                .stroke(.white, lineWidth: 1.5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("\(cell.id): \(Self.formatTokens(cell.tokens)) tokens")
        }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Text("Less")
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.35))
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Self.color(for: level))
                    .frame(width: 8, height: 8)
            }
            Text("More")
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private static func color(for level: Int) -> Color {
        switch level {
        case 1: Color(red: 0.29, green: 0.24, blue: 0.55)
        case 2: Color(red: 0.42, green: 0.35, blue: 0.78)
        case 3: Color(red: 0.55, green: 0.49, blue: 1.0)
        case 4: Color(red: 0.75, green: 0.70, blue: 1.0)
        default: Color.white.opacity(0.07)
        }
    }

    private static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 { return String(format: "%.2fB", Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()
}

// MARK: - Day Detail Card

/// Drill-down for a heatmap day: totals, hourly distribution, models,
/// apps, and projects.
struct GlassDayDetailCard: View {
    let detail: LedgerDayDetail
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(Self.displayDate(detail.date))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
            }

            // Headline stats
            HStack(spacing: 14) {
                stat(Self.formatTokens(detail.totals.totalTokens), "Tokens")
                divider
                stat(String(format: "$%.2f", detail.totals.costUSD), "Cost", color: .green)
                divider
                stat("\(detail.totals.entryCount)", "Messages")
                divider
                stat("\(detail.byModel.count)", "Models")
            }

            // Hourly distribution
            hourChart

            // Models
            if !detail.byModel.isEmpty {
                breakdownRows(
                    title: "MODELS",
                    rows: detail.byModel
                        .sorted { $0.value.costUSD > $1.value.costUSD }
                        .prefix(3)
                        .map { (label: Self.shortModel($0.key), totals: $0.value) }
                )
            }

            // Apps
            if !detail.bySource.isEmpty {
                breakdownRows(
                    title: "APPS",
                    rows: detail.bySource
                        .sorted { $0.value.costUSD > $1.value.costUSD }
                        .map { (label: $0.key.displayName, totals: $0.value) }
                )
            }

            // Projects
            if !detail.byProject.isEmpty {
                breakdownRows(
                    title: "PROJECTS",
                    rows: detail.byProject.prefix(3).map { (label: $0.displayName, totals: $0.totals) }
                )
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.12, green: 0.09, blue: 0.26))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(red: 0.55, green: 0.49, blue: 1.0).opacity(0.35), lineWidth: 1)
                }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var divider: some View {
        Divider().frame(height: 24).overlay(Color.white.opacity(0.1))
    }

    private func stat(_ value: String, _ label: String, color: Color = .white) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    private var hourChart: some View {
        let maxTokens = max(1, detail.byHour.values.map(\.totalTokens).max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("BY HOUR")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<24, id: \.self) { hour in
                    let tokens = detail.byHour[hour]?.totalTokens ?? 0
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            tokens > 0
                                ? Color(red: 0.55, green: 0.49, blue: 1.0)
                                : Color.white.opacity(0.08)
                        )
                        .frame(height: max(3, 30 * CGFloat(tokens) / CGFloat(maxTokens)))
                        .frame(maxWidth: .infinity)
                        .help(tokens > 0 ? "\(hour):00 — \(Self.formatTokens(tokens)) tokens" : "\(hour):00")
                }
            }
            .frame(height: 32, alignment: .bottom)
            HStack {
                Text("12am").font(.system(size: 7.5)).foregroundStyle(.white.opacity(0.3))
                Spacer()
                Text("12pm").font(.system(size: 7.5)).foregroundStyle(.white.opacity(0.3))
                Spacer()
                Text("11pm").font(.system(size: 7.5)).foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private func breakdownRows(title: String, rows: [(label: String, totals: TokenTotals)]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
            ForEach(rows, id: \.label) { row in
                HStack {
                    Text(row.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer()
                    Text(Self.formatTokens(row.totals.totalTokens))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(String(format: "$%.2f", row.totals.costUSD))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green.opacity(0.9))
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    static func shortModel(_ model: String) -> String {
        model.replacingOccurrences(of: "claude-", with: "")
    }

    static func displayDate(_ key: String) -> String {
        guard let date = TokenLedger.parseDayKey(key) else { return key }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }

    private static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 { return String(format: "%.2fB", Double(count) / 1_000_000_000) }
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

/// Placeholder while a day's drill-down loads.
struct GlassDayDetailLoading: View {
    let date: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.55)
                .tint(.white.opacity(0.6))
            Text(GlassDayDetailCard.displayDate(date))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.12, green: 0.09, blue: 0.26))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                }
        }
    }
}

// MARK: - Preview

#Preview {
    PremiumDashboardView(
        usageStore: UsageStore(),
        settingsStore: SettingsStore(),
        ledgerStore: TokenLedgerStore(),
        onRefresh: {},
        onSettings: {},
        onQuit: {},
        onClose: {}
    )
}
