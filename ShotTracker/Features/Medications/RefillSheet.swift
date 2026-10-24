import Atelier
import SwiftUI

/// "Log refill": how many units came, as an Atelier sheet (medium and large detents, Cancel and Add in the navigation
/// bar on iOS). It used to be an alert with a text field, which couldn't say what was wrong with a bad number.
struct RefillSheet: View {
    let unitLabel: String
    let containerNoun: String
    let onLog: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quantityText: String

    init(defaultQuantity: Int, unitLabel: String, containerNoun: String, onLog: @escaping (Int) -> Void) {
        self.unitLabel = unitLabel
        self.containerNoun = containerNoun
        self.onLog = onLog
        _quantityText = State(initialValue: defaultQuantity > 0 ? String(defaultQuantity) : "")
    }

    /// The quantity when the text is a whole number above zero.
    static func quantity(from text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value
    }

    private var quantity: Int? { Self.quantity(from: quantityText) }

    private var error: String? {
        quantityText.trimmingCharacters(in: .whitespaces).isEmpty || quantity != nil
            ? nil : "Enter a whole number of \(unitLabel), more than 0."
    }

    var body: some View {
        SheetScaffold(verbatim: "Log refill",
                      subtitle: "How many \(unitLabel) did you get? This adds a new \(containerNoun) to your supply.",
                      systemImage: "shippingbox", size: .compact) {
            TextInput(title: Text(verbatim: "Quantity"), text: $quantityText, prompt: Text(verbatim: "0"),
                      error: error)
                .keyboardType(.numberPad)
                .componentIdentifier(AccessibilityID.refillQuantityField)
        } footer: {
            // A disabledReason always disables the primary: pass one only while the quantity is invalid.
            ActionFooter("Add", disabledReason: quantity == nil ? "Enter how many you got." : nil) {
                guard let quantity else { return }
                onLog(quantity)
                dismiss()
            }
        }
    }
}
