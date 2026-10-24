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
            Row(spacing: .xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .textRole(.actionTitle)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum)
        }
        .buttonStyle(ActionButtonStyle(kind: kind))
        .applying(accessibilityIdentifier: accessibilityIdentifier, accessibilityHint: accessibilityHint)
    }
}

private struct ActionButtonStyle: ButtonStyle {
    @Environment(\.themeContext) private var ctx

    let kind: ActionButton.Kind

    func makeBody(configuration: Configuration) -> some View {
        let width = ctx.isIncreasedContrast ? Theme.BorderWidth.highContrast : Theme.BorderWidth.regular

        configuration.label
            .background(background, in: ctx.shape(.control))
            .foregroundStyle(foreground)
            .overlay(ctx.shape(.control).strokeBorder(borderColor, lineWidth: width))
            .opacity(configuration.isPressed ? 0.7 : 1) // ds-allow: pressed feedback, as before
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary(let urgent): AnyShapeStyle(urgent ? .tone(.danger, .fill) : Theme.Color.accent)
        case .secondary, .quiet: AnyShapeStyle(.clear)
        }
    }

    private var foreground: ThemeColor {
        switch kind {
        case .primary(let urgent): urgent ? .tone(.danger, .onFill) : Theme.Color.accentOn
        case .secondary: Theme.Color.textPrimary
        case .quiet: Theme.Color.textSecondary
        }
    }

    private var borderColor: ThemeColor {
        switch kind {
        case .primary(let urgent): urgent ? .tone(.danger, .fill) : Theme.Color.accent
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

/// Take/Snooze/Skip row for a dose: side by side, full-width buttons one under the other
/// at the accessibility text sizes (Atelier's `AdaptiveStack(stacking: .atAccessibilitySizes)`,
/// one layout, so a button keeps its identity and focus when the size changes).
struct DoseActionBar: View {

    let doseID: UUID
    let status: DoseStatus
    var onTake: () -> Void
    /// nil hides Snooze (an upcoming dose, or a medication whose reminders disallow it).
    var onSnooze: (() -> Void)?
    var onSkip: () -> Void

    var body: some View {
        AdaptiveStack(horizontalAlignment: .center, spacing: .s, stacking: .atAccessibilitySizes) { buttons }
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
