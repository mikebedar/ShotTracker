import SwiftUI

/// Section title used above dose-card groups. `.attention` tone (used for the
/// Overdue bucket) swaps in an alert icon and status-overdue coloring.
struct SectionHeader: View {
    enum Tone {
        case regular
        case attention
    }

    let title: String
    var count: Int?
    var tone: Tone = .regular

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s2) {
            if tone == .attention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Color.statusOverdue)
            }

            Text(title)
                .font(Theme.Font.display(.title3))
                .foregroundStyle(tone == .attention ? Theme.Color.statusOverdue : Theme.Color.textPrimary)

            Spacer()

            if let count {
                Text("\(count)")
                    .font(Theme.Font.text(.caption).weight(.bold))
                    .padding(.horizontal, Theme.Spacing.s2)
                    .padding(.vertical, 3)
                    .background(tone == .attention ? Theme.Color.statusOverdueSoft : .clear, in: Capsule())
                    .foregroundStyle(tone == .attention ? Theme.Color.statusOverdue : Theme.Color.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
