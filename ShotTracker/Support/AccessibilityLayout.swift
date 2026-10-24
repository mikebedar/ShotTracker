import SwiftUI

// Rows that sit side by side stack at the accessibility sizes (AX1–AX5) through Atelier's
// `AdaptiveStack(stacking: .atAccessibilitySizes)` (ShotTracker's own `AdaptiveStack`, which did
// the same, went with the Atelier adoption). At AX5 the horizontal rows left names a few letters
// wide — "Letro/zole", one word per line — or pushed cards off screen.

extension DynamicTypeSize {
    /// Artwork and other fixed-size chrome scale with text up to this size, no further.
    static let artworkScaleCap: DynamicTypeSize = .xxxLarge
}
