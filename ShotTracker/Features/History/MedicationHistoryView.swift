import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Shares the history as a proper .csv attachment. The string is built on the main actor
/// (where the SwiftData models live) and carried here as a plain value.
private struct HistoryCSVDocument: Transferable {
    let csv: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { document in
            Data(document.csv.utf8)
        }
        .suggestedFileName("ShotTracker-History.csv")
    }
}

struct MedicationHistoryView: View {
    @Environment(\.appDependencies) private var dependencies
    @Query(sort: [SortDescriptor(\DoseEvent.loggedAt, order: .reverse)]) private var events: [DoseEvent]
    @Query(sort: [SortDescriptor(\ScheduledDose.scheduledAt)]) private var doses: [ScheduledDose]
    @Query private var refillEvents: [RefillEvent]
    @State private var selectedMedicationID: UUID?

    private var adherence: AdherenceStats.Stats {
        let relevant = selectedMedicationID.map { id in doses.filter { $0.medication?.id == id } } ?? doses
        return AdherenceStats.compute(
            doses: relevant,
            statusFor: { dependencies.statusEvaluator.effectiveStatus(for: $0) }
        )
    }

    /// Every medication that appears in history — archived ones included, since
    /// preserving their history is the whole point of soft-delete.
    private var medicationsWithHistory: [Medication] {
        var seen = Set<UUID>()
        var result: [Medication] = []
        for event in events {
            guard let medication = event.medication, seen.insert(medication.id).inserted else { continue }
            result.append(medication)
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    private var filteredEvents: [DoseEvent] {
        guard let selectedMedicationID else { return events }
        return events.filter { $0.medication?.id == selectedMedicationID }
    }

    /// Events grouped by calendar month, newest month first (events are already sorted
    /// newest-first, so group order follows from first appearance).
    private var monthGroups: [(month: Date, events: [DoseEvent])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var groups: [Date: [DoseEvent]] = [:]
        for event in filteredEvents {
            let components = calendar.dateComponents([.year, .month], from: event.loggedAt)
            guard let month = calendar.date(from: components) else { continue }
            if groups[month] == nil { order.append(month) }
            groups[month, default: []].append(event)
        }
        return order.map { (month: $0, events: groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if events.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "clock",
                        description: Text("Dose actions will appear here after you log them.")
                    )
                } else {
                    if adherence.adherencePercent != nil {
                        Section {
                            adherenceCard
                        }
                    }

                    ForEach(monthGroups, id: \.month) { group in
                        Section {
                            ForEach(group.events) { event in
                                DoseEventRow(event: event)
                            }
                        } header: {
                            Text(group.month.formatted(.dateTime.month(.wide).year()))
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !events.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(
                            item: HistoryCSVDocument(csv: HistoryCSVExporter.csv(doseEvents: events, refillEvents: refillEvents)),
                            preview: SharePreview("Dose History", image: Image(systemName: "tablecells"))
                        ) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if medicationsWithHistory.count > 1 {
                    filterChips
                }
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s2) {
                chip(title: "All", isSelected: selectedMedicationID == nil) {
                    selectedMedicationID = nil
                }
                ForEach(medicationsWithHistory) { medication in
                    chip(
                        title: medication.displayName,
                        isSelected: selectedMedicationID == medication.id
                    ) {
                        selectedMedicationID = medication.id
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, Theme.Spacing.s2)
        }
        .background(.bar)
    }

    private var adherenceCard: some View {
        HStack(spacing: Theme.Spacing.s4) {
            statTile(
                value: adherence.adherencePercent.map { "\($0)%" } ?? "—",
                label: "30-day adherence",
                emphasized: true
            )
            statTile(value: "\(adherence.currentStreakDays)", label: "day streak")
            if let slot = adherence.mostMissedSlot {
                statTile(value: SlotTitle.title(label: slot), label: "most missed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.s2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(adherenceAccessibilityLabel)
    }

    private func statTile(value: String, label: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.Font.display(.title2))
                .foregroundStyle(emphasized ? Theme.Color.accentStrong : Theme.Color.textPrimary)
            Text(label)
                .font(Theme.Font.text(.caption))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var adherenceAccessibilityLabel: String {
        var parts: [String] = []
        if let percent = adherence.adherencePercent {
            parts.append("\(percent) percent adherence over the last 30 days")
        }
        parts.append("\(adherence.currentStreakDays) day streak")
        if let slot = adherence.mostMissedSlot {
            parts.append("most missed slot: \(SlotTitle.title(label: slot))")
        }
        return parts.joined(separator: ", ")
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.text(.footnote).weight(.semibold))
                .foregroundStyle(isSelected ? Theme.Color.accentOn : Theme.Color.textSecondary)
                .padding(.horizontal, Theme.Spacing.s3)
                .padding(.vertical, Theme.Spacing.s2)
                .background(
                    Capsule().fill(isSelected ? Theme.Color.accent : Theme.Color.accentSoft.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Shows only this medication's history.")
    }
}
