import SwiftData
import SwiftUI

/// Per-medication history: logged dose actions and refills, interleaved by date.
struct MedicationHistoryDetailView: View {
    let medication: Medication

    private enum HistoryEntry: Identifiable {
        case dose(DoseEvent)
        case refill(RefillEvent)

        var id: String {
            switch self {
            case .dose(let event): "dose-\(event.id.uuidString)"
            case .refill(let event): "refill-\(event.id.uuidString)"
            }
        }

        var loggedAt: Date {
            switch self {
            case .dose(let event): event.loggedAt
            case .refill(let event): event.loggedAt
            }
        }
    }

    private var entries: [HistoryEntry] {
        let doses = medication.doseEvents.map(HistoryEntry.dose)
        let refills = medication.refillEvents.map(HistoryEntry.refill)
        return (doses + refills).sorted { $0.loggedAt > $1.loggedAt }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock",
                    description: Text("Dose actions and refills will appear here.")
                )
            } else {
                ForEach(entries) { entry in
                    switch entry {
                    case .dose(let event):
                        DoseEventRow(event: event, showMedicationName: false)
                    case .refill(let event):
                        refillRow(event)
                    }
                }
            }
        }
        .navigationTitle("History")
    }

    private func refillRow(_ event: RefillEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Refilled +\(event.quantity) \(medication.supplyUnitLabel ?? "units")", systemImage: "arrow.clockwise.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Color.accentStrong)
            Text(event.loggedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
