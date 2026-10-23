import SwiftUI

/// Transient bottom-floating notification pill. No existing pattern for this in the
/// app; scoped as a local view + modifier rather than a global toast manager.
struct Toast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Font.text(.subheadline).weight(.semibold))
            .padding(.horizontal, Theme.Spacing.s4)
            .padding(.vertical, Theme.Spacing.s2)
            .background(Theme.Color.textPrimary, in: Capsule())
            .foregroundStyle(Theme.Color.background)
            .shadow(color: Theme.Color.shadowCard, radius: 12, y: 6)
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Toast(text: message)
                        .padding(.bottom, Theme.Spacing.s7)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(2.2))
                            if self.message == message { self.message = nil }
                        }
                }
            }
            .animation(.default, value: message)
    }
}

extension View {
    /// Shows a bottom-floating toast whenever `message` is non-nil, then auto-clears it.
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}
