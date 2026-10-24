import Atelier
import SwiftUI

/// Friendly banner for "nothing to do" states — e.g. the Today screen when every scheduled
/// dose is handled but there's still a look-ahead list below. A tinted Atelier surface in its
/// tone (Atelier's `EmptyState` is for a whole empty screen; this sits above a list).
struct EmptyStateBanner: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    var tone: Tone = .success

    var body: some View {
        Column(alignment: .center, spacing: .s) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.tone(tone))

            Text(title)
                .textRole(.heading)
                .auditsFit("emptyBanner.title")

            if let subtitle {
                Text(subtitle)
                    .textRole(.explain)
                    .multilineTextAlignment(.center)
                    .auditsFit("emptyBanner.subtitle")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.xl)
        .surface(.tinted(tone), radius: .card)
        .accessibilityElement(children: .combine)
    }
}
