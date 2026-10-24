import Atelier
import SwiftUI

/// Small uppercase date label used inside the long-range "Coming Up" list.
struct DateGroupLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Font.text(.caption2).weight(.heavy))
            .foregroundStyle(Theme.Color.textTertiary)
            .tracking(0.4)
    }
}
