import SwiftUI
import Atelier

/// Design-token namespace: spacing, radii, and semantic typography.
/// Colors live in `Theme+Color.swift` since they're backed by the asset catalog.
enum Theme {
    enum Spacing {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s7: CGFloat = 32
        static let s8: CGFloat = 40
    }

    enum Radius {
        static let card: CGFloat = 20
        static let avatar: CGFloat = 14
        // No `.pill` constant — use `Capsule()` directly, it's the native equivalent
        // of the design's `radius-pill: 999px` token.
    }

    enum BorderWidth {
        static let regular: CGFloat = 1
        static let highContrast: CGFloat = 1.75
    }

    /// Semantic type styles. Display styles use the rounded system font design as a
    /// stand-in for the source design's bundled "Nunito" — same warm/geometric feel
    /// with zero extra font assets, and it still scales with Dynamic Type for free.
    enum Font {
        static func display(_ style: SwiftUI.Font.TextStyle, weight: SwiftUI.Font.Weight = .bold) -> SwiftUI.Font {
            .system(style, design: .rounded).weight(weight)
        }

        static func text(_ style: SwiftUI.Font.TextStyle) -> SwiftUI.Font {
            .system(style)
        }
    }
}

/// Applies a themed, contrast-aware border. Width switches between `Theme.BorderWidth.regular`
/// and `.highContrast` based on `@Environment(\.colorSchemeContrast)` — the design's
/// `[data-contrast="high"]` variant only changes border weight (and swaps to the "strong"
/// border color), it doesn't introduce new colors, so no separate asset-catalog contrast
/// axis is needed for this.
private struct ThemedBorderModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    let color: ThemeColor
    let strongColor: ThemeColor
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let width = contrast == .increased ? Theme.BorderWidth.highContrast : Theme.BorderWidth.regular
        let resolvedColor = contrast == .increased ? strongColor : color
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(resolvedColor, lineWidth: width)
        )
    }
}

extension View {
    /// Themed border that respects Increase Contrast. Pass `color`/`strongColor` explicitly
    /// for components (like `StatusPill`) whose border is a semantic color rather than the
    /// generic border/border-strong pair.
    func themedBorder(
        color: ThemeColor = Theme.Color.border,
        strongColor: ThemeColor = Theme.Color.borderStrong,
        cornerRadius: CGFloat
    ) -> some View {
        modifier(ThemedBorderModifier(color: color, strongColor: strongColor, cornerRadius: cornerRadius))
    }
}

private struct ThemedCapsuleBorderModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    let color: ThemeColor

    func body(content: Content) -> some View {
        let width = contrast == .increased ? Theme.BorderWidth.highContrast : Theme.BorderWidth.regular
        content.overlay(Capsule().strokeBorder(color, lineWidth: width))
    }
}

extension View {
    /// Contrast-aware capsule border in a single semantic `color` (the design specs pill
    /// borders as "currentColor", i.e. the status's own color — not the generic border pair).
    func themedCapsuleBorder(_ color: ThemeColor) -> some View {
        modifier(ThemedCapsuleBorderModifier(color: color))
    }
}

/// ShotTracker's text roles on Atelier's ramp (Dynamic Type styles, so they follow Larger Text to AX5 and the
/// Text Size setting). Titles take the theme's display design: SF Rounded in ShotTracker's theme.
extension TextRole {
    /// A medication's name on a card or row.
    static let doseName = TextRole("doseName", style: .headline, usesHeadingWeight: true, usesDisplayDesign: true)
    /// The timing line under it.
    static let doseTiming = TextRole("doseTiming", style: .subheadline, color: .secondary)
    /// Small print: the canonical name, the other clock, footers.
    static let doseDetail = TextRole("doseDetail", style: .footnote, color: .tertiary)
    /// Take / Snooze / Skip.
    static let actionTitle = TextRole("actionTitle", style: .subheadline, weight: .bold)
}
