import SwiftUI
import ControlTowerCore

/// Token-focused usage chart with model breakdown and cost overlay
/// NOTE: This tracks Claude Code CLI usage only, not claude.ai web or Claude Desktop
struct ClaudeCostChartView: View {
    let dailyCosts: [ClaudeCostScanner.DailyCost]
    let period: Period
    let updatedAt: Date?
    let isLoading: Bool

    enum Period: String, CaseIterable {
        case week = "7 Days"
        case month = "30 Days"

        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            }
        }
    }

    init(
        dailyCosts: [ClaudeCostScanner.DailyCost],
        period: Period,
        updatedAt: Date? = nil,
        isLoading: Bool = false
    ) {
        self.dailyCosts = dailyCosts
        self.period = period
        self.updatedAt = updatedAt
        self.isLoading = isLoading
    }

    @State private var hoveredIndex: Int?
    @State private var hoveredData: DayData?

    // MARK: - Computed Data

    private var chartData: [DayData] {
        let calendar = Calendar.current
        let now = Date()
        var items: [DayData] = []

        for dayOffset in (0..<period.days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let key = Self.dayKey(from: date)

            if let cost = dailyCosts.first(where: { $0.date == key }) {
                items.append(DayData(
                    index: items.count,
                    date: key,
                    dailyCost: cost
                ))
            } else {
                items.append(DayData(
                    index: items.count,
                    date: key,
                    dailyCost: nil
                ))
            }
        }
        return items
    }

    private var maxTokens: Int {
        max(chartData.compactMap { $0.totalTokens }.max() ?? 1, 1)
    }

    private var totalTokens: Int {
        chartData.reduce(0) { $0 + ($1.totalTokens ?? 0) }
    }

    private var totalCost: Double {
        chartData.reduce(0) { $0 + ($1.costUSD ?? 0) }
    }

    private var modelStats: [ModelStat] {
        var stats: [String: (tokens: Int, cost: Double)] = [:]

        for day in chartData {
            guard let breakdown = day.dailyCost?.modelBreakdown else { continue }
            for (model, usage) in breakdown {
                let normalized = Self.normalizeModelName(model)
                let existing = stats[normalized] ?? (0, 0)
                stats[normalized] = (
                    existing.tokens + usage.totalTokens,
                    existing.cost + usage.costUSD
                )
            }
        }

        return stats.map { ModelStat(name: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
            .sorted { $0.tokens > $1.tokens }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            headerView

            if isLoading && dailyCosts.isEmpty {
                // Loading skeleton
                loadingView
            } else {
                // Chart with fixed tooltip area
                VStack(spacing: 0) {
                    // Tooltip area (fixed height to prevent jumping)
                    tooltipArea
                        .frame(height: 44)

                    // Main chart
                    chartView
                }

                // Model breakdown bar
                if !modelStats.isEmpty {
                    modelBreakdownView
                }

                // Footer stats
                footerView
            }

            // Data source and timestamp
            sourceAndTimestampView
        }
        .padding(16)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            // Skeleton bars
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 24, height: CGFloat([40, 60, 30, 80, 50, 70, 45][i]))
                        .shimmer()
                }
            }
            .frame(height: 100)

            // Skeleton model bar
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.15))
                .frame(height: 16)
                .shimmer()

            // Skeleton stats
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 80, height: 12)
                Spacer()
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 100, height: 12)
            }
            .shimmer()
        }
    }

    private var sourceAndTimestampView: some View {
        HStack {
            Image(systemName: "terminal.fill")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text("Claude Code CLI")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Spacer()

            if isLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                    Text("Scanning...")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            } else if let updated = updatedAt {
                Text("as of \(formatTimestamp(updated))")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "h:mm a"
            return "Yesterday \(formatter.string(from: date))"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
            return formatter.string(from: date)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("\(period.days) days")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Total tokens (primary) and cost (secondary)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.formatTokens(totalTokens))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(String(format: "$%.2f", totalCost))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Tooltip Area (Fixed position - no jumping)

    @ViewBuilder
    private var tooltipArea: some View {
        if let day = hoveredData {
            VStack(alignment: .leading, spacing: 4) {
                // Row 1: Date, Tokens, Cost
                HStack(spacing: 0) {
                    // Date
                    Text(fullDate(day.date))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    // Tokens (prominent)
                    HStack(spacing: 4) {
                        Text(Self.formatTokens(day.totalTokens ?? 0))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text("tokens")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    // Divider
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 8)

                    // Cost
                    Text(String(format: "$%.2f", day.costUSD ?? 0))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                }

                // Row 2: Model breakdown
                if let breakdown = day.dailyCost?.modelBreakdown, !breakdown.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(breakdown.sorted { $0.value.totalTokens > $1.value.totalTokens }.prefix(3), id: \.key) { model, usage in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Self.colorForModel(model))
                                    .frame(width: 6, height: 6)
                                Text(Self.shortModelName(model))
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(Self.formatTokensCompact(usage.totalTokens))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else {
            // Placeholder when not hovering
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Hover over bars for daily breakdown")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                Color.clear.frame(height: 12)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Chart

    private var chartView: some View {
        GeometryReader { geo in
            let barWidth = calculateBarWidth(totalWidth: geo.size.width)
            let spacing = calculateSpacing(totalWidth: geo.size.width, barWidth: barWidth)
            let chartHeight = geo.size.height - 16

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(chartData) { day in
                    dayBarView(
                        day: day,
                        barWidth: barWidth,
                        maxHeight: chartHeight
                    )
                }
            }
        }
        .frame(height: 100)
    }

    private func dayBarView(day: DayData, barWidth: CGFloat, maxHeight: CGFloat) -> some View {
        let isHovered = hoveredIndex == day.index
        let tokens = day.totalTokens ?? 0
        let barHeight = tokens > 0
            ? max(8, CGFloat(Double(tokens) / Double(maxTokens)) * (maxHeight - 16))
            : 4

        return VStack(spacing: 2) {
            Spacer(minLength: 0)

            // Stacked bar by model
            stackedBar(day: day, barWidth: barWidth, totalHeight: barHeight, isHovered: isHovered)

            // Date label
            if shouldShowLabel(for: day.index) {
                Text(shortDate(day.date))
                    .font(.system(size: 9, weight: isHovered ? .bold : .medium))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .lineLimit(1)
            } else {
                Color.clear.frame(height: 11)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                if hovering {
                    hoveredIndex = day.index
                    hoveredData = day
                } else {
                    hoveredIndex = nil
                    hoveredData = nil
                }
            }
        }
    }

    @ViewBuilder
    private func stackedBar(day: DayData, barWidth: CGFloat, totalHeight: CGFloat, isHovered: Bool) -> some View {
        if let breakdown = day.dailyCost?.modelBreakdown, !breakdown.isEmpty {
            let sortedModels = breakdown.sorted { $0.value.totalTokens > $1.value.totalTokens }
            let totalDayTokens = day.totalTokens ?? 1

            VStack(spacing: 0) {
                ForEach(Array(sortedModels.enumerated()), id: \.offset) { idx, entry in
                    let proportion = Double(entry.value.totalTokens) / Double(totalDayTokens)
                    let segmentHeight = max(2, totalHeight * proportion)
                    let color = Self.colorForModel(entry.key)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: isHovered
                                    ? [color, color.opacity(0.85)]
                                    : [color.opacity(0.8), color.opacity(0.55)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: segmentHeight)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: barWidth > 12 ? 4 : 2))
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: barWidth > 12 ? 4 : 2)
                        .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                }
            }
            .shadow(
                color: isHovered ? Self.colorForModel(sortedModels.first?.key ?? "").opacity(0.5) : .clear,
                radius: isHovered ? 8 : 0,
                y: isHovered ? 3 : 0
            )
            .scaleEffect(y: isHovered ? 1.02 : 1.0, anchor: .bottom)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        } else {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray.opacity(isHovered ? 0.3 : 0.15))
                .frame(width: barWidth, height: 4)
        }
    }

    // MARK: - Model Breakdown Bar

    private var modelBreakdownView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model Mix")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(modelStats) { stat in
                        let proportion = totalTokens > 0 ? Double(stat.tokens) / Double(totalTokens) : 0
                        let width = max(proportion > 0.02 ? 16 : 0, geo.size.width * proportion)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.colorForModel(stat.name).gradient)
                            .frame(width: width)
                            .overlay(alignment: .center) {
                                if proportion > 0.18 {
                                    Text(Self.shortModelName(stat.name))
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                }
            }
            .frame(height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Legend
            HStack(spacing: 10) {
                ForEach(modelStats.prefix(3)) { stat in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Self.colorForModel(stat.name))
                            .frame(width: 6, height: 6)

                        Text(Self.shortModelName(stat.name))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)

                        Text(Self.formatTokensCompact(stat.tokens))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)

                        Text(String(format: "$%.0f", stat.cost))
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.green.opacity(0.8))
                    }
                }

                Spacer()
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // Input/Output breakdown
            if totalTokens > 0 {
                let inputTokens = chartData.reduce(0) { $0 + ($1.dailyCost?.inputTokens ?? 0) }
                let outputTokens = chartData.reduce(0) { $0 + ($1.dailyCost?.outputTokens ?? 0) }

                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue.opacity(0.7))
                        Text(Self.formatTokensCompact(inputTokens))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green.opacity(0.7))
                        Text(Self.formatTokensCompact(outputTokens))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Average per day
            if totalTokens > 0 {
                let activeDays = chartData.filter { ($0.totalTokens ?? 0) > 0 }.count
                let avgTokens = totalTokens / max(1, activeDays)
                let avgCost = totalCost / Double(max(1, activeDays))

                HStack(spacing: 4) {
                    Text("Avg:")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("\(Self.formatTokensCompact(avgTokens))/day")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(String(format: "$%.0f", avgCost))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Calculations

    private func calculateBarWidth(totalWidth: CGFloat) -> CGFloat {
        let count = CGFloat(period.days)
        let totalSpacing = (count - 1) * 3
        let availableWidth = totalWidth - totalSpacing
        return max(8, min(28, availableWidth / count))
    }

    private func calculateSpacing(totalWidth: CGFloat, barWidth: CGFloat) -> CGFloat {
        let count = CGFloat(period.days)
        let totalBarWidth = barWidth * count
        let remainingSpace = totalWidth - totalBarWidth
        return max(2, remainingSpace / (count - 1))
    }

    private func shouldShowLabel(for index: Int) -> Bool {
        let count = chartData.count
        if count <= 7 { return true }
        return index == 0 || index == count - 1 || (index + 1) % 7 == 0
    }

    // MARK: - Formatting

    private func shortDate(_ dateKey: String) -> String {
        let parts = dateKey.split(separator: "-")
        guard parts.count == 3, let day = Int(parts[2]) else { return dateKey }
        return "\(day)"
    }

    private func fullDate(_ dateKey: String) -> String {
        let parts = dateKey.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return dateKey }
        let monthNames = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard month >= 1, month <= 12 else { return dateKey }
        return "\(monthNames[month]) \(day)"
    }

    private static func dayKey(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.2fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    static func formatTokensCompact(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if count >= 1_000_000 {
            return String(format: "%.0fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    static func normalizeModelName(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("opus") { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku") { return "haiku" }
        return model
    }

    static func shortModelName(_ model: String) -> String {
        let normalized = normalizeModelName(model)
        switch normalized {
        case "opus": return "Opus"
        case "sonnet": return "Sonnet"
        case "haiku": return "Haiku"
        default: return String(model.prefix(8))
        }
    }

    static func colorForModel(_ model: String) -> Color {
        let normalized = normalizeModelName(model)
        switch normalized {
        case "opus": return Color.orange
        case "sonnet": return Color.blue
        case "haiku": return Color.green
        default: return Color.purple
        }
    }
}

// MARK: - Data Models

private struct DayData: Identifiable, Equatable {
    let index: Int
    let date: String
    let dailyCost: ClaudeCostScanner.DailyCost?

    var id: String { date }

    var totalTokens: Int? {
        dailyCost?.totalTokens
    }

    var costUSD: Double? {
        dailyCost?.costUSD
    }

    static func == (lhs: DayData, rhs: DayData) -> Bool {
        lhs.date == rhs.date && lhs.index == rhs.index
    }
}

private struct ModelStat: Identifiable {
    let name: String
    let tokens: Int
    let cost: Double

    var id: String { name }
}

// MARK: - Shimmer Effect

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    Color.white.opacity(0.3),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: -geo.size.width * 0.3 + phase * geo.size.width * 1.6)
                }
                .mask(content)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Preview

#if DEBUG
struct ClaudeCostChartView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Normal state with data
            ClaudeCostChartView(
                dailyCosts: [
                    .init(date: "2026-02-11", inputTokens: 30_000_000, outputTokens: 20_000_000, cacheReadTokens: 5_000_000, cacheWriteTokens: 0, costUSD: 82.50, modelBreakdown: [
                        "claude-opus-4-5-20251101": .init(inputTokens: 10_000_000, outputTokens: 8_000_000, cacheReadTokens: 2_000_000, cacheWriteTokens: 0, costUSD: 65.00),
                        "claude-sonnet-4-5-20250514": .init(inputTokens: 20_000_000, outputTokens: 12_000_000, cacheReadTokens: 3_000_000, cacheWriteTokens: 0, costUSD: 17.50)
                    ]),
                    .init(date: "2026-02-12", inputTokens: 15_000_000, outputTokens: 10_000_000, cacheReadTokens: 2_000_000, cacheWriteTokens: 0, costUSD: 35.00, modelBreakdown: [
                        "claude-sonnet-4-5-20250514": .init(inputTokens: 15_000_000, outputTokens: 10_000_000, cacheReadTokens: 2_000_000, cacheWriteTokens: 0, costUSD: 35.00)
                    ]),
                    .init(date: "2026-02-13", inputTokens: 50_000_000, outputTokens: 30_000_000, cacheReadTokens: 10_000_000, cacheWriteTokens: 0, costUSD: 150.00, modelBreakdown: [
                        "claude-opus-4-5-20251101": .init(inputTokens: 40_000_000, outputTokens: 25_000_000, cacheReadTokens: 8_000_000, cacheWriteTokens: 0, costUSD: 130.00),
                        "claude-haiku-4-5-20251001": .init(inputTokens: 10_000_000, outputTokens: 5_000_000, cacheReadTokens: 2_000_000, cacheWriteTokens: 0, costUSD: 20.00)
                    ]),
                    .init(date: "2026-02-15", inputTokens: 25_000_000, outputTokens: 15_000_000, cacheReadTokens: 5_000_000, cacheWriteTokens: 0, costUSD: 55.00, modelBreakdown: [
                        "claude-sonnet-4-5-20250514": .init(inputTokens: 25_000_000, outputTokens: 15_000_000, cacheReadTokens: 5_000_000, cacheWriteTokens: 0, costUSD: 55.00)
                    ]),
                    .init(date: "2026-02-16", inputTokens: 80_000_000, outputTokens: 50_000_000, cacheReadTokens: 15_000_000, cacheWriteTokens: 0, costUSD: 200.00, modelBreakdown: [
                        "claude-opus-4-5-20251101": .init(inputTokens: 60_000_000, outputTokens: 40_000_000, cacheReadTokens: 10_000_000, cacheWriteTokens: 0, costUSD: 170.00),
                        "claude-sonnet-4-5-20250514": .init(inputTokens: 20_000_000, outputTokens: 10_000_000, cacheReadTokens: 5_000_000, cacheWriteTokens: 0, costUSD: 30.00)
                    ]),
                    .init(date: "2026-02-17", inputTokens: 20_000_000, outputTokens: 12_000_000, cacheReadTokens: 3_000_000, cacheWriteTokens: 0, costUSD: 45.00, modelBreakdown: [
                        "claude-sonnet-4-5-20250514": .init(inputTokens: 20_000_000, outputTokens: 12_000_000, cacheReadTokens: 3_000_000, cacheWriteTokens: 0, costUSD: 45.00)
                    ]),
                ],
                period: .week,
                updatedAt: Date()
            )
            .frame(width: 360, height: 320)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)

            // Loading state
            ClaudeCostChartView(
                dailyCosts: [],
                period: .week,
                isLoading: true
            )
            .frame(width: 360, height: 320)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
