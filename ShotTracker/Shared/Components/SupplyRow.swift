import SwiftUI

/// Remaining-supply indicator for a dose card. Visualizes the *current* container
/// (pips for small container sizes, a thin bar otherwise) and shows the total on hand
/// across all containers. A static "Running low" note (no consumption forecasting) plus
/// an optional "Remind me" action appear when supply is low.
struct SupplyRow: View {
    let currentContainerRemaining: Int
    let unitsPerContainer: Int
    let totalRemaining: Int
    let unitLabel: String
    let containerNoun: String
    let isLow: Bool
    /// Projected run-out line ("Runs out Jul 28 (~12 days)"); nil hides it.
    var forecastText: String?
    var onRemindMe: (() -> Void)?

    private var showPips: Bool { unitsPerContainer > 0 && unitsPerContainer <= 10 }
    private var progress: Double {
        unitsPerContainer > 0 ? min(max(Double(currentContainerRemaining) / Double(unitsPerContainer), 0), 1) : 0
    }
    private var indicatorColor: Color { isLow ? Theme.Color.statusOverdue : Theme.Color.accent }
    private var hasMultipleContainers: Bool { totalRemaining > currentContainerRemaining }

    private var summaryText: String {
        if hasMultipleContainers {
            return "\(currentContainerRemaining) in current \(containerNoun) · \(totalRemaining) \(Self.unit(unitLabel, count: totalRemaining)) total"
        }
        return "\(totalRemaining) \(Self.unit(unitLabel, count: totalRemaining)) left"
    }

    /// "1 dose left", not "1 doses left": the stored label is the plural.
    static func unit(_ label: String, count: Int) -> String {
        guard count == 1, label.count > 1, label.lowercased().hasSuffix("s") else { return label }
        return String(label.dropLast())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
            AdaptiveStack(spacing: Theme.Spacing.s2) {
                if showPips {
                    HStack(spacing: 3) {
                        ForEach(0..<unitsPerContainer, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(index < currentContainerRemaining ? indicatorColor : Theme.Color.border)
                                .frame(width: 7, height: 7)
                        }
                    }
                } else {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.Color.border)
                            Capsule()
                                .fill(indicatorColor)
                                .frame(width: geometry.size.width * progress)
                        }
                    }
                    .frame(width: 56, height: 6)
                }

                Text(summaryText)
                    .font(Theme.Font.text(.footnote).weight(.bold))
                    .foregroundStyle(isLow ? Theme.Color.statusOverdue : Theme.Color.textSecondary)
            }

            if let forecastText {
                Label(forecastText, systemImage: "calendar.badge.clock")
                    .font(Theme.Font.text(.caption))
                    .foregroundStyle(isLow ? Theme.Color.statusOverdue : Theme.Color.textSecondary)
            }

            if isLow {
                HStack {
                    Label("Running low", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.text(.caption))
                        .foregroundStyle(Theme.Color.statusOverdue)

                    Spacer()

                    if let onRemindMe {
                        Button("Remind me", action: onRemindMe)
                            .font(Theme.Font.text(.caption).weight(.bold))
                            .foregroundStyle(Theme.Color.accentStrong)
                    }
                }
            }
        }
        .padding(.top, Theme.Spacing.s3)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Color.border).frame(height: Theme.BorderWidth.regular)
        }
    }
}
