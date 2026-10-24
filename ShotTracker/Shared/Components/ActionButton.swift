import Atelier
import SwiftUI

/// Generic themed button used for dose actions (and reusable anywhere else a
/// primary/secondary/quiet action is needed). Min 44pt tap height per the design.
struct ActionButton: View {
    enum Kind {
        case primary(urgent: Bool = false)
        case secondary
        case quiet
    }

    let title: String
    var systemImage: String?
    let kind: Kind
    var role: ButtonRole?
    let action: () -> Void
    var accessibilityIdentifier: String?
    var accessibilityHint: String?

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(Theme.Font.text(.subheadline).weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(ActionButtonStyle(kind: kind))
        .applying(accessibilityIdentifier: accessibilityIdentifier, accessibilityHint: accessibilityHint)
    }
}

private struct ActionButtonStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast

    let kind: ActionButton.Kind

    func makeBody(configuration: Configuration) -> some View {
        let width = contrast == .increased ? Theme.BorderWidth.highContrast : Theme.BorderWidth.regular

        configuration.label
            .background(background, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .foregroundStyle(foreground)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: width)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary(let urgent): AnyShapeStyle(urgent ? Theme.Color.statusOverdue : Theme.Color.accent)
        case .secondary, .quiet: AnyShapeStyle(.clear)
        }
    }

    private var foreground: ThemeColor {
        switch kind {
        case .primary: Theme.Color.accentOn
        case .secondary: Theme.Color.textPrimary
        case .quiet: Theme.Color.textSecondary
        }
    }

    private var borderColor: ThemeColor {
        switch kind {
        case .primary(let urgent): urgent ? Theme.Color.statusOverdue : Theme.Color.accent
        case .secondary: Theme.Color.borderStrong
        case .quiet: Theme.Color.border
        }
    }
}

private extension View {
    @ViewBuilder
    func applying(accessibilityIdentifier: String?, accessibilityHint: String?) -> some View {
        switch (accessibilityIdentifier, accessibilityHint) {
        case let (.some(id), .some(hint)):
            self.accessibilityIdentifier(id).accessibilityHint(hint)
        case let (.some(id), .none):
            self.accessibilityIdentifier(id)
        case let (.none, .some(hint)):
            self.accessibilityHint(hint)
        case (.none, .none):
            self
        }
    }
}

/// Take/Snooze/Skip row for a dose. Adapts to vertical layout at accessibility text
/// sizes, ported from the layout logic previously duplicated in `TodayView`.
struct DoseActionBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let doseID: UUID
    let status: DoseStatus
    var onTake: () -> Void
    /// nil hides Snooze (an upcoming dose, or a medication whose reminders disallow it).
    var onSnooze: (() -> Void)?
    var onSkip: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: Theme.Spacing.s2) { buttons }
            } else {
                HStack(spacing: Theme.Spacing.s2) { buttons }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        ActionButton(
            title: "Take",
            systemImage: "checkmark",
            kind: .primary(urgent: status == .overdue),
            action: onTake,
            accessibilityIdentifier: AccessibilityID.takeDoseButton(doseID),
            accessibilityHint: "Logs this scheduled dose as taken."
        )
        if let onSnooze {
            ActionButton(
                title: "Snooze",
                systemImage: "moon",
                kind: .quiet,
                action: onSnooze,
                accessibilityIdentifier: AccessibilityID.snoozeDoseButton(doseID),
                accessibilityHint: "Moves the reminder later."
            )
        }
        ActionButton(
            title: "Skip",
            systemImage: "minus.circle",
            kind: .secondary,
            role: .destructive,
            action: onSkip,
            accessibilityIdentifier: AccessibilityID.skipDoseButton(doseID),
            accessibilityHint: "Marks this scheduled dose as skipped."
        )
    }
}
