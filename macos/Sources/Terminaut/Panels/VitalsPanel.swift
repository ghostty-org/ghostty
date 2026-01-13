import SwiftUI

/// Shows context usage and quota as visual gauges
struct VitalsPanel: View {
    let state: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelHeader("VITALS")

            VStack(alignment: .leading, spacing: 12) {
                vitalGauge(
                    label: "Context",
                    value: state.contextPercent ?? 0,
                    color: contextColor
                )

                vitalGauge(
                    label: "Quota",
                    value: state.quotaPercent ?? 0,
                    color: quotaColor
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(panelBackground)
    }

    private func vitalGauge(label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)

                Spacer()

                Text(String(format: "%.0f%%", value))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 8)

                    // Value bar
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(value / 100.0), height: 8)
                }
            }
            .frame(height: 8)
        }
    }

    private var contextColor: Color {
        guard let value = state.contextPercent else { return .gray }
        if value >= 80 { return .red }
        if value >= 60 { return .orange }
        return .cyan
    }

    private var quotaColor: Color {
        guard let value = state.quotaPercent else { return .gray }
        if value >= 80 { return .red }
        if value >= 60 { return .orange }
        return .green
    }
}
