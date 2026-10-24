import Foundation
import SwiftData
import SwiftUI
import Testing
import Atelier
import AtelierTestingCore
@testable import ShotTracker

/// Every component the Atelier adoption touched, laid out on a phone (375 pt iPhone SE, 402 pt iPhone 17) at AX5 and at
/// the default size, through Atelier's `LayoutProbe.accessibilityFit`: nothing wider than the screen, no text marked
/// `.auditsFit` cut short, nothing marked off the edge. ShotTracker was already good at AX5; this keeps it so.
@MainActor
@Suite(.serialized)
struct AccessibilityFitTests {
    private static let widths: [CGFloat] = [375, 402]
    private static let variants: [Snapshot.Variant] = [
        .init(scheme: .dark, dynamicTypeSize: .accessibility5),
        .init(scheme: .light, dynamicTypeSize: .accessibility3),
        .init(scheme: .dark, dynamicTypeSize: .large),
    ]

    /// A long name, a canonical name, supply tracking and take-with-food: the busiest card there is.
    private func fixture() throws -> (Medication, [ScheduledDose]) {
        let context = try TestSupport.makeContext()
        let now = Date.now
        let medication = try TestSupport.medication(
            "Hydroxychloroquine sulfate",
            timings: [DailyTiming(kind: .morning), DailyTiming(kind: .evening)],
            anchor: Calendar.current.startOfDay(for: now),
            timeZone: TimeZone.current.identifier,
            context: context
        )
        medication.canonicalName = "hydroxychloroquine sulfate 200 mg tablet"
        medication.takeWithFood = true
        medication.supplyUnitLabel = "tablets"
        medication.unitsPerContainer = 8
        medication.supplyContainers = [2, 8]
        medication.supplyLowThreshold = 5
        try TestSupport.refresh(context, at: now)
        let doses = medication.scheduledDoses.sorted { $0.scheduledAt < $1.scheduledAt }
        #expect(!doses.isEmpty)
        return (medication, doses)
    }

    private func check(_ name: String, _ view: some View) -> [String] {
        var failures: [String] = []
        for width in Self.widths {
            for variant in Self.variants {
                let report = LayoutProbe.accessibilityFit(
                    of: view.padding(.l).atelierTheme(ShotTrackerTheme.theme),
                    width: width, variant: variant
                )
                if !report.passed { failures.append("\(name) @ \(width) \(variant): \(report)") }
            }
        }
        return failures
    }

    @Test func doseCardsFit() throws {
        let (_, doses) = try fixture()
        let dose = try #require(doses.first)
        var failures: [String] = []
        for status in [DoseStatus.due, .overdue, .snoozed, .upcoming] {
            failures += check("DoseCard \(status)", DoseCard(
                dose: dose, status: status, onTake: {}, onSnooze: status == .upcoming ? nil : {}, onSkip: {}, onUndo: {}
            ))
        }
        dose.completedAt = .now
        failures += check("DoseCard taken", DoseCard(dose: dose, status: .takenLate, onUndo: {}))
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func rowsFit() throws {
        let (medication, doses) = try fixture()
        let dose = try #require(doses.first)
        var failures: [String] = []
        failures += check("SimpleDoseRow", SimpleDoseRow(dose: dose, medication: medication, status: .overdue))
        failures += check("ComingUpRow", ComingUpRow(dose: dose, medication: medication))
        failures += check("MedicationSummaryRow", MedicationSummaryRow(medication: medication))
        failures += check("SupplyRow", SupplyRow(currentContainerRemaining: 2, unitsPerContainer: 8, totalRemaining: 10,
                                                 unitLabel: "tablets", containerNoun: "bottle", isLow: true,
                                                 forecastText: "Runs out Jul 28 (~12 days)", onRemindMe: {}))
        failures += check("EmptyStateBanner", EmptyStateBanner(title: "You're all caught up", systemImage: "checkmark.circle.fill",
                                                               subtitle: "Every dose scheduled for today is handled."))
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func actionBarFits() {
        let bar = DoseActionBar(doseID: UUID(), status: .overdue, onTake: {}, onSnooze: {}, onSkip: {})
        let failures = check("DoseActionBar", bar)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func refillSheetFits() {
        let sheet = RefillSheet(defaultQuantity: 90, unitLabel: "tablets", containerNoun: "bottle") { _ in }
        let failures = check("RefillSheet", sheet)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Settings → Appearance: Atelier's own controls over ShotTracker's themes.
    @Test func appearanceControlsFit() {
        let preferences = AtelierPreferences(transient: ShotTrackerTheme.defaults, themes: ShotTrackerTheme.themes,
                                             defaults: ShotTrackerTheme.defaults)
        var failures: [String] = []
        failures += check("ThemePicker", ThemePicker(preferences))
        failures += check("AppearancePicker", AppearancePicker(preferences))
        // Atelier's AccentPicker runs off a phone at AX sizes; Settings shows a menu there (AccentChoiceRow).
        failures += check("AccentPicker", AccentPicker(preferences).dynamicTypeSize(...DynamicTypeSize.xxxLarge))
        failures += check("TextSizePicker", TextSizePicker(preferences))
        failures += check("FeedbackSettings", FeedbackSettings(preferences))
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// The probe isn't vacuous: it measures the card's marked text, and catches a name squeezed into a narrow column.
    @Test func theProbeSeesTheCardsText() throws {
        let (_, doses) = try fixture()
        let dose = try #require(doses.first)
        let card = DoseCard(dose: dose, status: .due, onTake: {}, onSkip: {})
        let report = LayoutProbe.accessibilityFit(of: card.atelierTheme(ShotTrackerTheme.theme), width: 402)
        #expect(report.measuredTexts >= 3, "\(report)")

        let cut = Text(verbatim: "Hydroxychloroquine sulfate").textRole(.doseName).auditsFit("cut").lineLimit(1)
        let cutReport = LayoutProbe.accessibilityFit(of: cut.frame(width: 120), width: 375) // ds-allow: a deliberately cut fixture
        #expect(!cutReport.truncated.isEmpty, "\(cutReport)")
    }

    /// Refill quantities: whole numbers above zero only.
    @Test func refillQuantity() {
        #expect(RefillSheet.quantity(from: "90") == 90)
        #expect(RefillSheet.quantity(from: " 12 ") == 12)
        #expect(RefillSheet.quantity(from: "0") == nil)
        #expect(RefillSheet.quantity(from: "-3") == nil)
        #expect(RefillSheet.quantity(from: "abc") == nil)
        #expect(RefillSheet.quantity(from: "") == nil)
    }
}
