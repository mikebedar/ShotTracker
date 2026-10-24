import Foundation
import Testing
@testable import ShotTracker

@MainActor
struct HistoryCSVExporterTests {
    @Test func escapesCommasQuotesAndNewlines() {
        #expect(HistoryCSVExporter.escape("plain") == "plain")
        #expect(HistoryCSVExporter.escape("a,b") == "\"a,b\"")
        #expect(HistoryCSVExporter.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(HistoryCSVExporter.escape("line\nbreak") == "\"line\nbreak\"")
    }

    @Test func buildsHeaderAndRowsNewestFirst() {
        let medication = Medication(displayName: "Test Med", supplyUnitLabel: "tablets")
        let older = DoseEvent(loggedAt: Date(timeIntervalSince1970: 1_000), action: .taken, medication: medication)
        let newer = RefillEvent(loggedAt: Date(timeIntervalSince1970: 2_000), quantity: 30, medication: medication)

        let csv = HistoryCSVExporter.csv(doseEvents: [older], refillEvents: [newer])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[0] == "Date,Time,Time Zone,Medication,Event,Detail,Note")
        #expect(lines.count == 3)
        #expect(lines[1].contains("Refill"))
        #expect(lines[1].contains("+30 tablets"))
        #expect(lines[2].contains("Taken"))
        #expect(lines[2].contains("Test Med"))
    }

    @Test func noteWithCommaSurvivesRoundTrip() {
        let medication = Medication(displayName: "Med, With Comma")
        let event = DoseEvent(action: .skipped, note: "felt sick, skipped", medication: medication)
        let csv = HistoryCSVExporter.csv(doseEvents: [event], refillEvents: [])
        #expect(csv.contains("\"Med, With Comma\""))
        #expect(csv.contains("\"felt sick, skipped\""))
    }
}
