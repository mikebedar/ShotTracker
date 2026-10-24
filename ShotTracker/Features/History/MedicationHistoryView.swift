import Atelier
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
                    // Filter chips live in the list: as a top safe-area inset they covered
                    // the navigation title, so the tab showed no "History" heading.
                    if medicationsWithHistory.count > 1 {
                        Section {
                            filterChips
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }

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
                            item: HistoryCSVDocument(csv: HistoryCSVExporter.csv(doseEvents: events, refillEvents: refillEvents, dayParts: dependencies.preferencesStore.preferences.dayParts)),
                            preview: SharePreview("Dose History", image: Image(systemName: "tablecells"))
                        ) {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    /// One chip per medication with history (archived ones included) plus All; picking one shows only its history.
    private var filterChips: some View {
        ChipBar(.scrolling) {
            Chip("All", isSelected: Binding(
                get: { selectedMedicationID == nil },
                set: { if $0 { selectedMedicationID = nil } }
            ))
            .accessibilityHint("Shows every medication's history.")
            ForEach(medicationsWithHistory) { medication in
                Chip(verbatim: medication.displayName, isSelected: Binding(
                    get: { selectedMedicationID == medication.id },
                    set: { selectedMedicationID = $0 ? medication.id : nil }
                ))
                .accessibilityHint("Shows only this medication's history.")
            }
        }
        .padding(.vertical, .xs)
    }

    /// Atelier's stats: equal columns, one per row on a phone at the accessibility sizes, the figure never cut.
    private var adherenceCard: some View {
        StatGrid(maximumColumns: 2) {
            Stat(verbatim: "30-day adherence", value: adherence.adherencePercent.map { "\($0)%" } ?? "—",
                 systemImage: "percent")
                .valueTone(.accent)
            Stat(verbatim: "Day streak", value: "\(adherence.currentStreakDays)", systemImage: "flame")
            if let slot = adherence.mostMissedSlot {
                Stat(verbatim: "Most missed", value: SlotTitle.title(label: slot), systemImage: "exclamationmark.circle")
                    .valueStyle(.text)
            }
            if adherence.snoozedCount > 0 {
                Stat(verbatim: "Taken after a snooze", value: "\(adherence.snoozedCount)",
                     systemImage: DoseStatus.snoozed.symbolName)
            }
        }
        .statStyle(.plain)
        .padding(.vertical, .s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(adherenceAccessibilityLabel)
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
        if adherence.snoozedCount > 0 {
            parts.append("\(adherence.snoozedCount) taken after a snooze")
        }
        return parts.joined(separator: ", ")
    }
}
