import Atelier
import SwiftUI

/// Friendly themed banner for "nothing to do" states — e.g. the Today screen when
/// every scheduled dose is handled but there's still a look-ahead list below.
struct EmptyStateBanner: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    var tint: ThemeColor = Theme.Color.statusTaken

    var body: some View {
        VStack(spacing: Theme.Spacing.s2) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(tint)

            Text(title)
                .font(Theme.Font.display(.title3))
                .foregroundStyle(Theme.Color.textPrimary)

            if let subtitle {
                Text(subtitle)
                    .font(Theme.Font.text(.subheadline))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.s6)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
