import Charts
import ControlTowerCore
import SwiftUI

/// Chart showing usage over time for a provider.
struct UsageChartView: View {
    let data: [ChartDataPoint]
    let title: String
    let color: Color

    init(data: [ChartDataPoint], title: String = "Usage", color: Color = .blue) {
        self.data = data
        self.title = title
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            if data.isEmpty {
                Text("No data available")
                    .foregroundStyle(.tertiary)
                    .frame(height: 120)
            } else {
                Chart(data) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Usage", point.value)
                    )
                    .foregroundStyle(color.gradient)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("Usage", point.value)
                    )
                    .foregroundStyle(color.opacity(0.1).gradient)
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text("\(intValue)%")
                                    .font(.caption2)
                            }
                        }
                        AxisGridLine()
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisValueLabel(format: .dateTime.hour())
                        AxisGridLine()
                    }
                }
                .frame(height: 120)
            }
        }
    }
}

/// Chart showing usage comparison across providers.
struct ProvidersComparisonChart: View {
    let data: [ProviderUsageData]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider Comparison")
                .font(.headline)
                .foregroundStyle(.secondary)

            if data.isEmpty {
                Text("No data available")
                    .foregroundStyle(.tertiary)
                    .frame(height: 150)
            } else {
                Chart(data) { provider in
                    BarMark(
                        x: .value("Provider", provider.name),
                        y: .value("Usage", provider.usedPercent)
                    )
                    .foregroundStyle(by: .value("Provider", provider.name))
                    .cornerRadius(4)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text("\(intValue)%")
                                    .font(.caption2)
                            }
                        }
                        AxisGridLine()
                    }
                }
                .frame(height: 150)
            }
        }
    }
}

/// Chart showing daily cost breakdown.
struct CostChartView: View {
    let data: [DailyCostData]
    let currency: String

    init(data: [DailyCostData], currency: String = "USD") {
        self.data = data
        self.currency = currency
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Daily Cost")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                if let total = totalCost {
                    Text(String(format: "$%.2f total", total))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if data.isEmpty {
                Text("No cost data")
                    .foregroundStyle(.tertiary)
                    .frame(height: 100)
            } else {
                Chart(data) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Cost", point.cost)
                    )
                    .foregroundStyle(.green.gradient)
                    .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let doubleValue = value.as(Double.self) {
                                Text(String(format: "$%.2f", doubleValue))
                                    .font(.caption2)
                            }
                        }
                        AxisGridLine()
                    }
                }
                .frame(height: 100)
            }
        }
    }

    private var totalCost: Double? {
        guard !data.isEmpty else { return nil }
        return data.reduce(0) { $0 + $1.cost }
    }
}

/// Mini sparkline chart for inline usage display.
struct SparklineChart: View {
    let data: [Double]
    let color: Color

    var body: some View {
        if data.isEmpty {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 50, height: 20)
        } else {
            Chart(Array(data.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Index", index),
                    y: .value("Value", value)
                )
                .foregroundStyle(color)
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(width: 50, height: 20)
        }
    }
}

// MARK: - Data Types

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double

    init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

struct ProviderUsageData: Identifiable {
    let id: ProviderID
    let name: String
    let usedPercent: Double
    let color: Color

    init(provider: ProviderID, usedPercent: Double) {
        self.id = provider
        self.name = provider.displayName
        self.usedPercent = usedPercent
        self.color = Self.color(for: provider)
    }

    static func color(for provider: ProviderID) -> Color {
        switch provider {
        case .claude: return .orange
        case .codex: return .green
        case .cursor: return .purple
        case .gemini: return .blue
        case .copilot: return .cyan
        case .antigravity: return Color(red: 0.376, green: 0.729, blue: 0.494)
        }
    }
}

struct DailyCostData: Identifiable {
    let id = UUID()
    let date: Date
    let cost: Double
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        UsageChartView(
            data: (0..<24).map { i in
                ChartDataPoint(
                    date: Date().addingTimeInterval(-Double(i) * 3600),
                    value: Double.random(in: 20...80)
                )
            }.reversed(),
            title: "Claude Usage (24h)",
            color: .orange
        )

        ProvidersComparisonChart(
            data: ProviderID.allCases.map { provider in
                ProviderUsageData(provider: provider, usedPercent: Double.random(in: 10...90))
            }
        )

        CostChartView(
            data: (0..<7).map { i in
                DailyCostData(
                    date: Date().addingTimeInterval(-Double(i) * 86400),
                    cost: Double.random(in: 0.5...5.0)
                )
            }.reversed()
        )
    }
    .padding()
    .frame(width: 350)
}
