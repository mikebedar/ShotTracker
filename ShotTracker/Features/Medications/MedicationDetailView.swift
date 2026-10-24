import Atelier
import SwiftData
import SwiftUI

struct MedicationDetailView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let medication: Medication

    @State private var isPresentingEdit = false
    @State private var isPresentingRefill = false
    @State private var feedbackPulse: FeedbackPulse?
    @Environment(\.presenter) private var presenter

    private var regimen: MedicationRegimen? {
        medication.regimens.active
    }

    private var supplyForecastText: String? {
        SupplyForecastService.projection(
            for: medication,
            engine: dependencies.scheduleEngine,
            preferences: dependencies.preferencesStore.preferences
        ).map { SupplyForecastService.summaryText(for: $0) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    AdaptiveStack(spacing: .m, stacking: .atAccessibilitySizes) {
                        MedicationArtworkView(medication: medication)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(medication.displayName)
                                .font(.title3.weight(.semibold))
                            if let canonicalName = AppFormatting.medicationSubtitle(for: medication) {
                                Text(canonicalName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let selectedStrengthAndForm = medication.selectedStrengthAndForm {
                                Text(selectedStrengthAndForm)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let regimen {
                        Text(AppFormatting.scheduleText(for: regimen))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if medication.takeWithFood {
                        Label("Take with food", systemImage: "fork.knife")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !medication.notes.isEmpty {
                        Text(medication.notes)
                            .font(.body)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilitySummary)
            }

            if let regimen, ZonedTimeFormatter(home: regimen.homeTimeZone).differs(at: .now) {
                Section {
                    homeTimeZoneNote(for: regimen.homeTimeZone)
                }
            }

            if medication.isTrackingSupply, let unitLabel = medication.supplyUnitLabel {
                Section("Supply") {
                    SupplyRow(
                        currentContainerRemaining: medication.currentContainerRemaining,
                        unitsPerContainer: medication.unitsPerContainer ?? medication.totalRemaining,
                        totalRemaining: medication.totalRemaining,
                        unitLabel: unitLabel,
                        containerNoun: medication.kind.containerNoun,
                        isLow: medication.isSupplyLow,
                        forecastText: supplyForecastText
                    )
                    if let lastRefilledAt = medication.lastRefilledAt {
                        Text("Last refilled \(lastRefilledAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Log refill") {
                        isPresentingRefill = true
                    }
                }
            }

            Section {
                NavigationLink {
                    MedicationScheduledDosesView(medication: medication)
                } label: {
                    Label("Scheduled doses", systemImage: "calendar")
                }
                NavigationLink {
                    MedicationHistoryDetailView(medication: medication)
                } label: {
                    Label("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                if medication.drugLabelInfo?.hasContent == true {
                    NavigationLink {
                        MedicationDrugInfoView(medication: medication)
                    } label: {
                        Label("Drug Info", systemImage: "cross.case")
                    }
                }
            }

            if let regimen {
                Section(String(localized: "How this schedule works", comment: "Detail: the schedule summary's heading")) {
                    ScheduleSummaryView(summary: ScheduleSummary(
                        ScheduleSummary.Inputs(regimen: regimen),
                        preferences: dependencies.preferencesStore.preferences
                    ))
                    .padding(.vertical, Theme.Spacing.s1)
                }
            }

            Section {
                Button("Delete Medication", role: .destructive) {
                    deleteMedication()
                }
                .accessibilityIdentifier(AccessibilityID.deleteMedicationButton)
            }
        }
        .navigationTitle("Details")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    isPresentingEdit = true
                }
            }
        }
        .sheet(isPresented: $isPresentingEdit) {
            NavigationStack {
                EditMedicationView(medication: medication)
            }
        }
        .sheet(isPresented: $isPresentingRefill) {
            RefillSheet(defaultQuantity: medication.unitsPerContainer ?? 0,
                        unitLabel: medication.supplyUnitLabel ?? "units",
                        containerNoun: medication.kind.containerNoun) { quantity in
                logRefill(quantity)
            }
        }
        .feedback(feedbackPulse)
    }

    /// Shown only away from the schedule's home zone: which clock the times are on, how
    /// far the device is from it, and where to change it.
    private func homeTimeZoneNote(for home: TimeZone) -> some View {
        let name = ZonedTimeFormatter.displayName(of: home)
        let difference = (TimeZone.current.secondsFromGMT() - home.secondsFromGMT()) / 60
        let offset = SnoozeWording.duration(minutes: abs(difference))
        let relation = difference > 0 ? "\(offset) ahead of" : "\(offset) behind"
        return Label {
            VStack(alignment: .leading, spacing: Theme.Spacing.s1) {
                Text("Home time zone: \(name)")
                    .font(.subheadline.weight(.semibold))
                Text(travelExplanation(relation: relation))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "globe")
                .foregroundStyle(Theme.Color.accentStrong)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.homeTimeZoneNote)
    }

    /// What travelling does to this medication's doses (`MedicationRegimen.travelPolicy`).
    private func travelExplanation(relation: String) -> String {
        let timings = regimen?.timings ?? []
        let policies = Set(timings.map { regimen?.travelPolicy(for: $0) ?? TravelTimePolicy.defaultFor(kind: $0.kind) })
        let place = SlotClockLabel.placeName(of: .current)
        let what: String
        if policies == [.followsMe] {
            what = String(localized: "Its doses follow you: they move to \(place) time, like “Morning (\(place))”, and show the time at home too.", comment: "Detail note: a medication whose doses follow the device")
        } else if policies == [.staysOnHome] {
            what = String(localized: "Its doses stay at their home times and show both clocks, like “8:00 AM home · 2:00 PM here”; reminders come at the home time.", comment: "Detail note: a medication kept on home time")
        } else {
            what = String(localized: "Its named times follow you to \(place) time; its specific times stay at their home times and show both clocks.", comment: "Detail note: a medication with both kinds of timing")
        }
        return String(localized: "This device is \(relation) it. \(what) “How this schedule works” below says what long flights do; change it in Edit → When you travel.", comment: "Detail note away from the home zone")
    }

    private func logRefill(_ quantity: Int) {
        dependencies.logRefill(quantity, for: medication, context: modelContext)
        let unit = SupplyRow.unit(medication.supplyUnitLabel ?? "units", count: quantity)
        presenter.toast(Toast(verbatim: "Added \(quantity) \(unit)", tone: .success))
        feedbackPulse = FeedbackPulse(role: .success)
    }

    /// Archives it (history stays) with Undo in the toast, and goes back to the list.
    private func deleteMedication() {
        MedicationArchiving.archive(medication, presenter: presenter, dependencies: dependencies, context: modelContext)
        if !medication.isActive { dismiss() }
    }

    private var accessibilitySummary: String {
        var parts = [medication.spokenName]
        if let regimen {
            parts.append(AppFormatting.scheduleText(for: regimen))
        }
        if !medication.notes.isEmpty {
            parts.append(medication.notes)
        }
        return parts.joined(separator: ". ")
    }
}
