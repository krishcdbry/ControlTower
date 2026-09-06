import Charts
import ControlTowerCore
import SwiftUI

struct CombinedUsageHomeCard: View {
    let snapshot: CombinedUsageSnapshot?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.cyan)
                    Text("Combined Usage").font(.system(size: 15, weight: .bold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
                Text("Claude + Codex · All local apps")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                if let snapshot {
                    HStack(spacing: 8) {
                        ForEach(UsageHistoryPeriod.allCases, id: \.self) { period in
                            let totals = snapshot.window(period).totals
                            VStack(spacing: 5) {
                                Text(period.title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                Text(CombinedUsageFormat.tokens(totals.totalTokens))
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                Text(CombinedUsageFormat.cost(totals.costUSD))
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading usage...").font(.system(size: 12))
                    }
                }
                Text("Explore daily, weekly, monthly and model usage")
                    .font(.system(size: 10)).foregroundStyle(.cyan.opacity(0.8))
            }
            .foregroundStyle(.white)
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [.cyan.opacity(0.12), .purple.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay { RoundedRectangle(cornerRadius: 16).stroke(.cyan.opacity(0.3), lineWidth: 1) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open combined usage analysis across Claude and Codex apps")
    }
}

struct CombinedUsageDetailView: View {
    let ledgerStore: TokenLedgerStore
    let enabledProviders: [ProviderID]
    let onBack: () -> Void

    @State private var period = UsageHistoryPeriod.week
    @State private var selectedDay: String?
    @State private var dayDetail: LedgerDayDetail?
    @State private var isLoadingDay = false

    private var requestedDay: String? {
        if period == .today, let snapshot = ledgerStore.combinedSnapshot {
            return TokenLedger.dayKey(for: snapshot.generatedAt, calendar: .current)
        }
        return selectedDay
    }

    private var detailTaskID: String {
        "\(requestedDay ?? ""):\(ledgerStore.combinedSnapshot?.generatedAt.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) {
                Label("Back to Overview", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)

            if let snapshot = ledgerStore.combinedSnapshot {
                let window = snapshot.window(period)
                summary(window)
                chart(window)
                if period != .today {
                    dayPicker(window)
                    if let selectedDay {
                        if let detail = dayDetail, detail.date == selectedDay {
                            GlassDayDetailCard(detail: detail, onDismiss: { self.selectedDay = nil }, costLabel: "Est. Cost", entryLabel: "Responses")
                        } else if isLoadingDay {
                            GlassDayDetailLoading(date: selectedDay)
                        } else {
                            Text("No activity recorded on \(CombinedUsageFormat.date(selectedDay)).")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).padding(12)
                        }
                    }
                }
                CombinedBreakdownCard(title: "By Provider", icon: "square.grid.2x2.fill", rows: window.byProvider.map {
                    .init(id: $0.key.rawValue, label: $0.key.displayName, totals: $0.value)
                })
                CombinedBreakdownCard(title: "By Model", icon: "cpu", rows: window.byModel.map {
                    .init(id: $0.key, label: GlassDayDetailCard.shortModel($0.key), totals: $0.value)
                })
                CombinedBreakdownCard(title: "By App", icon: "macwindow", rows: window.bySource.map {
                    .init(id: $0.key.rawValue, label: CombinedUsageFormat.source($0.key), totals: $0.value)
                })
                coverage(snapshot)
            } else {
                ProgressView("Loading combined usage...").padding(24).frame(maxWidth: .infinity)
            }
        }
        .onChange(of: period) { _, _ in selectedDay = nil }
        .task(id: detailTaskID) {
            dayDetail = nil
            guard let date = requestedDay else { isLoadingDay = false; return }
            isLoadingDay = true
            let result = await ledgerStore.combinedDayDetail(date)
            guard !Task.isCancelled else { return }
            dayDetail = result
            isLoadingDay = false
        }
    }

    private func summary(_ window: CombinedUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Combined Usage", systemImage: "square.stack.3d.up.fill")
                .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            Picker("Usage period", selection: $period) {
                ForEach(UsageHistoryPeriod.allCases, id: \.self) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CombinedUsageFormat.tokens(window.totals.totalTokens))
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("Total tokens").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(CombinedUsageFormat.cost(window.totals.costUSD))
                        .font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(.green)
                    Text("Estimated API cost").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            Text("\(window.byModel.count) models · \(window.totals.entryCount) responses · \(period.title)")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
        .foregroundStyle(.white)
        .modifier(CombinedCardSurface())
    }

    private func chart(_ window: CombinedUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(period == .today ? "Hourly Usage" : "Daily Usage", systemImage: "chart.bar.fill")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            if period == .today {
                if isLoadingDay {
                    ProgressView().frame(maxWidth: .infinity).frame(height: 115)
                } else {
                    Chart(0..<24, id: \.self) { hour in
                        BarMark(x: .value("Hour", hour), y: .value("Tokens", dayDetail?.byHour[hour]?.totalTokens ?? 0))
                            .foregroundStyle(.cyan.gradient).cornerRadius(2)
                    }
                    .chartXAxis {
                        AxisMarks(values: [0, 6, 12, 18]) { value in
                            AxisValueLabel {
                                if let hour = value.as(Int.self) {
                                    Text(String(format: "%02d:00", hour))
                                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                                }
                            }
                        }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 115)
                }
            } else {
                Chart(window.days, id: \.date) { day in
                    BarMark(x: .value("Date", day.date), y: .value("Tokens", day.totalTokens))
                        .foregroundStyle(day.date == selectedDay ? Color.cyan.gradient : Color.green.gradient)
                        .cornerRadius(3)
                }
                .chartXSelection(value: $selectedDay)
                .chartXAxis {
                    AxisMarks(values: window.days.enumerated().compactMap { index, day in
                        period == .week || index % 5 == 2 ? day.date : nil
                    }) { value in
                        AxisValueLabel {
                            if let date = value.as(String.self) {
                                Text(CombinedUsageFormat.date(date, format: period == .week ? "EEE" : "MMM d"))
                                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 115)
            }
            if let first = window.days.first, let last = window.days.last {
                Text(period == .today ? "Today, in your local timezone" : "\(CombinedUsageFormat.date(first.date)) to \(CombinedUsageFormat.date(last.date)) · Includes days with no activity")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .modifier(CombinedCardSurface())
    }

    private func dayPicker(_ window: CombinedUsageWindow) -> some View {
        Picker("Day details", selection: $selectedDay) {
            Text("Inspect a day").tag(String?.none)
            ForEach(window.days.reversed(), id: \.date) { day in
                Text("\(CombinedUsageFormat.date(day.date)) · \(CombinedUsageFormat.tokens(day.totalTokens)) tokens")
                    .tag(Optional(day.date))
            }
        }
        .pickerStyle(.menu).labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func coverage(_ snapshot: CombinedUsageSnapshot) -> some View {
        let unavailable = enabledProviders.filter { !snapshot.providers.contains($0) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Includes Claude and Codex activity recorded locally across desktop, Work/Cowork, CLI, IDE, and background agents.")
            if !unavailable.isEmpty {
                Text("Token history unavailable: \(unavailable.map(\.displayName).joined(separator: ", ")).")
            }
            DisclosureGroup("About estimated costs") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Costs use each model's API rates and include cached tokens. These are estimates of usage value, not subscription bills.")
                    Text("Codex estimates exclude fast-mode, long-context, cache-write, and tool charges. Reasoning tokens are included once in output.")
                    if let codex = ledgerStore.codexLedger, !codex.fallbackModels.isEmpty {
                        Text("Unlisted Codex models use \(CodexPricing.fallbackModel) rates: \(codex.fallbackModels.sorted().joined(separator: ", ")).")
                    }
                }
                .padding(.top, 5)
            }
            .tint(.cyan)
        }
        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 4)
    }
}

private struct CombinedBreakdownCard: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        let totals: TokenTotals
    }
    let title: String
    let icon: String
    let rows: [Row]

    private var sortedRows: [Row] {
        rows.sorted {
            $0.totals.totalTokens == $1.totals.totalTokens ? $0.id < $1.id : $0.totals.totalTokens > $1.totals.totalTokens
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 14, weight: .bold))
                Spacer()
                Text("Tokens / Est. Cost").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            }
            if rows.isEmpty {
                Text("No recorded activity in this period").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(sortedRows) { row in
                HStack(spacing: 8) {
                    Text(row.label).font(.system(size: 11, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle).help(row.id)
                    Spacer(minLength: 4)
                    Text(CombinedUsageFormat.tokens(row.totals.totalTokens))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(CombinedUsageFormat.cost(row.totals.costUSD)).foregroundStyle(.green)
                        .frame(minWidth: 60, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .modifier(CombinedCardSurface())
    }
}

private struct CombinedCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(16).background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.10, green: 0.08, blue: 0.22))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1) }
        }
    }
}

private enum CombinedUsageFormat {
    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }

    static func cost(_ value: Double) -> String { String(format: "~$%.2f", value) }

    static func date(_ key: String, format: String = "MMM d") -> String {
        guard let date = TokenLedger.parseDayKey(key) else { return key }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func source(_ source: UsageSource) -> String {
        switch source {
        case .claudeDesktop: "Claude Desktop / Cowork"
        case .codexDesktop: "Codex Desktop / Work"
        case .codexAgent: "Codex background agents"
        default: source.displayName
        }
    }
}
