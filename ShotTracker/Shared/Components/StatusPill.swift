import SwiftUI

/// Colored capsule badge for a `DoseStatus`. Reuses `DoseStatus.title`/`.symbolName`/
/// `.themeColor`/`.themeSoftColor` so the label text and coloring stay centralized.
struct StatusPill: View {
    enum Style {
        case regular
        case compact
    }

    let status: DoseStatus
    var style: Style = .regular

    var body: some View {
        Label {
            Text(status.title)
        } icon: {
            Image(systemName: status.symbolName)
        }
        .labelStyle(.titleAndIcon)
        .font(Theme.Font.text(style == .compact ? .caption2 : .caption).weight(.bold))
        .padding(.horizontal, style == .compact ? 9 : 11)
        .padding(.vertical, style == .compact ? 4 : 5)
        .background(status.themeSoftColor, in: Capsule())
        .foregroundStyle(status.themeColor)
        .themedCapsuleBorder(status.themeColor)
        .fixedSize()
    }
}
