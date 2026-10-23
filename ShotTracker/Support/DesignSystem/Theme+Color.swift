import SwiftUI

/// Color tokens. Backed by `Assets.xcassets/Theme/*.colorset` (Any + Dark appearance each),
/// converted from the source design's OKLCH values to sRGB via the standard OKLab conversion
/// (see `oklch(lightness:chroma:hueDegrees:)` below for the same math, kept for the avatar
/// hue system which needs it at runtime rather than as fixed swatches).
///
/// Access colors only through `Theme.Color.*` — never call `Color("...")` elsewhere, so a
/// typo'd asset name is a compile error everywhere it matters.
extension Theme {
    nonisolated enum Color {
        static var background: SwiftUI.Color { SwiftUI.Color("ColorBackground") }
        static var surface: SwiftUI.Color { SwiftUI.Color("ColorSurface") }
        static var surfaceSecondary: SwiftUI.Color { SwiftUI.Color("ColorSurfaceSecondary") }
        static var border: SwiftUI.Color { SwiftUI.Color("ColorBorder") }
        static var borderStrong: SwiftUI.Color { SwiftUI.Color("ColorBorderStrong") }
        static var textPrimary: SwiftUI.Color { SwiftUI.Color("ColorTextPrimary") }
        static var textSecondary: SwiftUI.Color { SwiftUI.Color("ColorTextSecondary") }
        static var textTertiary: SwiftUI.Color { SwiftUI.Color("ColorTextTertiary") }
        static var shadowCard: SwiftUI.Color { SwiftUI.Color("ColorShadowCard") }

        static var accent: SwiftUI.Color { SwiftUI.Color("ColorAccent") }
        static var accentStrong: SwiftUI.Color { SwiftUI.Color("ColorAccentStrong") }
        static var accentSoft: SwiftUI.Color { SwiftUI.Color("ColorAccentSoft") }
        static var accentOn: SwiftUI.Color { SwiftUI.Color("ColorAccentOn") }

        static var statusUpcoming: SwiftUI.Color { SwiftUI.Color("ColorStatusUpcoming") }
        static var statusUpcomingSoft: SwiftUI.Color { SwiftUI.Color("ColorStatusUpcomingSoft") }
        static var statusDue: SwiftUI.Color { SwiftUI.Color("ColorStatusDue") }
        static var statusDueSoft: SwiftUI.Color { SwiftUI.Color("ColorStatusDueSoft") }
        static var statusOverdue: SwiftUI.Color { SwiftUI.Color("ColorStatusOverdue") }
        static var statusOverdueSoft: SwiftUI.Color { SwiftUI.Color("ColorStatusOverdueSoft") }
        static var statusTaken: SwiftUI.Color { SwiftUI.Color("ColorStatusTaken") }
        static var statusTakenSoft: SwiftUI.Color { SwiftUI.Color("ColorStatusTakenSoft") }
        static var statusLate: SwiftUI.Color { SwiftUI.Color("ColorStatusLate") }
        static var statusLateSoft: SwiftUI.Color { SwiftUI.Color("ColorStatusLateSoft") }
        static var statusSkipped: SwiftUI.Color { SwiftUI.Color("ColorStatusSkipped") }
        static var statusSkippedSoft: SwiftUI.Color { SwiftUI.Color("ColorStatusSkippedSoft") }
        static var statusSnoozed: SwiftUI.Color { SwiftUI.Color("ColorStatusSnoozed") }
        static var statusSnoozedSoft: SwiftUI.Color { SwiftUI.Color("ColorStatusSnoozedSoft") }

        /// Per-medication avatar tint, parameterized by a hue angle (0..<360) derived from
        /// the medication's identity (see `Medication.avatarHue`) — mirrors the source
        /// design's `Avatar` component, which computes `background/color/border` from a
        /// single `hue` value per medication rather than a fixed palette. Computed at
        /// runtime (not asset-catalog-backed) since hue is continuous, not a fixed set.
        static func avatarTint(hueDegrees: Double, dark: Bool) -> AvatarTint {
            AvatarTint(
                background: oklch(lightness: dark ? 0.32 : 0.9, chroma: dark ? 0.05 : 0.045, hueDegrees: hueDegrees),
                foreground: oklch(lightness: dark ? 0.86 : 0.36, chroma: dark ? 0.06 : 0.09, hueDegrees: hueDegrees),
                border: oklch(lightness: dark ? 0.46 : 0.8, chroma: dark ? 0.07 : 0.06, hueDegrees: hueDegrees)
            )
        }
    }
}

struct AvatarTint {
    let background: Color
    let foreground: Color
    let border: Color
}

/// OKLCH → sRGB conversion (Björn Ottosson's OKLab formulation). Used only for the
/// continuous-hue avatar tint above; every other token is precomputed into the asset
/// catalog since it only ever takes two fixed values (light/dark).
private nonisolated func oklch(lightness L: Double, chroma C: Double, hueDegrees: Double) -> Color {
    let h = hueDegrees * .pi / 180
    let a = C * cos(h)
    let b = C * sin(h)

    let l_ = L + 0.3963377774 * a + 0.2158037573 * b
    let m_ = L - 0.1055613458 * a - 0.0638541728 * b
    let s_ = L - 0.0894841775 * a - 1.2914855480 * b

    let l = l_ * l_ * l_
    let m = m_ * m_ * m_
    let s = s_ * s_ * s_

    let rLin = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    let gLin = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    let bLin = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

    func toSRGB(_ c: Double) -> Double {
        let clamped = min(max(c, 0), 1)
        let v = clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return min(max(v, 0), 1)
    }

    return Color(red: toSRGB(rLin), green: toSRGB(gLin), blue: toSRGB(bLin))
}
