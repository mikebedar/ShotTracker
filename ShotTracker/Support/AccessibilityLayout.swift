import SwiftUI

/// Rows that sit side by side at normal text sizes and stack at the accessibility sizes
/// (AX1–AX5). At AX5 a horizontal row of artwork + text + a fixed-size status pill left
/// the text a few points wide — "Letro/zole", one word per line — or pushed the card off
/// screen. `DoseActionBar` already did this for its buttons; this is the same rule for
/// every other row.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var horizontalAlignment: VerticalAlignment = .center
    var spacing: CGFloat = Theme.Spacing.s3
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: horizontalAlignment, spacing: spacing))
        layout(content)
    }
}

extension DynamicTypeSize {
    /// Artwork and other fixed-size chrome scale with text up to this size, no further.
    static let artworkScaleCap: DynamicTypeSize = .xxxLarge
}
