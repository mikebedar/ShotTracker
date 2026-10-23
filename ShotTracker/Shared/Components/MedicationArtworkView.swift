import SwiftUI

/// Medication artwork: the medication's photo if set, otherwise a colored-letter
/// avatar (hue derived from `Medication.avatarHue`, initial from `displayName`) —
/// mirrors the source design's per-medication `Avatar` component.
struct MedicationArtworkView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric private var sideLength: CGFloat

    let medication: Medication

    init(medication: Medication, size: CGFloat = 44) {
        self.medication = medication
        self._sideLength = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    private var tint: AvatarTint {
        Theme.Color.avatarTint(hueDegrees: medication.avatarHue, dark: colorScheme == .dark)
    }

    private var initial: String {
        medication.displayName.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "?"
    }

    var body: some View {
        Group {
            if let imageData = medication.imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    tint.background
                    Text(initial)
                        .font(Theme.Font.display(.headline))
                        .foregroundStyle(tint.foreground)
                }
            }
        }
        .frame(width: sideLength, height: sideLength)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.avatar, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.avatar, style: .continuous)
                .strokeBorder(medication.imageData == nil ? tint.border : Theme.Color.border, lineWidth: Theme.BorderWidth.regular)
        )
        .accessibilityHidden(true)
    }
}
