import ControlTowerCore
import SwiftUI

struct CodexRecentUsageCard: View {
    let totals: TokenTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
                Text("Last 5 Hours").font(.system(size: 14, weight: .bold))
                Spacer()
                Text("Rolling local activity").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
            HStack(spacing: 12) {
                stat(tokens(totals.totalTokens), "Tokens")
                stat(String(format: "~$%.2f", totals.costUSD), "Est. Cost")
                stat(tokens(totals.totalTokens / 300), "Tokens/min avg")
                stat("\(totals.entryCount)", "Requests")
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.10, green: 0.08, blue: 0.22))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.25), lineWidth: 1) }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
        }.frame(maxWidth: .infinity)
    }

    private func tokens(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

struct CodexEstimateNote: View {
    let snapshot: CodexLedgerSnapshot

    var body: some View {
        DisclosureGroup("How costs are estimated") {
            VStack(alignment: .leading, spacing: 7) {
                Text("API-equivalent estimates from local tokens and published model rates, not subscription charges. Fast mode, long-context, cache-write, and tool charges are excluded.")
                Text("Reasoning, including Extra High, is included in output tokens and charged once at the model's output rate.")
                if !snapshot.fallbackModels.isEmpty {
                    Text("Unlisted models: \(snapshot.fallbackModels.sorted().joined(separator: ", ")).")
                    Text("Estimated at GPT-5.6 Sol rates: $4 input, $0.40 cached input, and $20 output per million tokens.")
                    Text(String(format: "Fallback portion (30 days): %.2fM tokens, ~$%.2f.", Double(snapshot.fallbackTokens) / 1_000_000, snapshot.fallbackCostUSD))
                } else {
                    Text("Unlisted models, if present in older days, use GPT-5.6 Sol rates as an estimate.")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 5)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.65))
        .tint(.cyan)
        .padding(.horizontal, 4)
    }
}

struct CodexModelUsageCard: View {
    let byModel: [String: TokenTotals]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cpu").foregroundStyle(.cyan)
                Text("By Model (30 Days)").font(.system(size: 14, weight: .bold))
                Spacer()
                Text("Est. Cost").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
            ForEach(byModel.keys.sorted { byModel[$0]!.costUSD > byModel[$1]!.costUSD }, id: \.self) { model in
                if let totals = byModel[model] {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model).font(.system(size: 11, weight: .semibold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                            Spacer(minLength: 8)
                            Text(String(format: "%.2fM", Double(totals.totalTokens) / 1_000_000))
                                .foregroundStyle(.white.opacity(0.6))
                            Text(String(format: "~$%.2f", totals.costUSD)).foregroundStyle(.green)
                        }
                        .font(.system(size: 11, weight: .medium))
                        if model == "codex-auto-review" {
                            Text("GPT-5.4 rate, per OpenAI's auto-review documentation")
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                        } else if CodexPricing.price(for: model) == nil {
                            Text("Estimated using \(CodexPricing.fallbackModel) rates")
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.10, green: 0.08, blue: 0.22))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12), lineWidth: 1) }
        }
    }
}
