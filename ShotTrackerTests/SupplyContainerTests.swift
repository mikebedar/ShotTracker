import Foundation
import Testing
@testable import ShotTracker

@MainActor
struct SupplyContainerTests {
    private static func trackedMedication(containers: [Int], perContainer: Int = 4) -> Medication {
        Medication(
            displayName: "Test",
            unitsPerContainer: perContainer,
            supplyContainers: containers,
            supplyUnitLabel: "doses"
        )
    }

    @Test func totalAndCurrentReflectContainers() {
        let med = Self.trackedMedication(containers: [1, 4])
        #expect(med.totalRemaining == 5)
        #expect(med.currentContainerRemaining == 1)
    }

    @Test func consumingCrossesContainerBoundary() {
        let med = Self.trackedMedication(containers: [1, 4])
        med.consumeOneUnit() // current vial had 1 → empties, drops, next (4) opens
        #expect(med.supplyContainers == [4])
        #expect(med.totalRemaining == 4)
        #expect(med.currentContainerRemaining == 4)
    }

    @Test func earlyRefillStacksBehindCurrent() {
        // 30 tablets left in the open bottle; a 90 refill arrives before it's empty.
        let med = Self.trackedMedication(containers: [30], perContainer: 90)
        med.addRefill(quantity: 90)
        #expect(med.supplyContainers == [30, 90])
        #expect(med.totalRemaining == 120)
        #expect(med.currentContainerRemaining == 30) // still finishing the open bottle
    }

    @Test func undoRestoresIntoCurrentContainer() {
        let med = Self.trackedMedication(containers: [4], perContainer: 4)
        med.consumeOneUnit()
        #expect(med.supplyContainers == [3])
        med.restoreOneUnit()
        #expect(med.supplyContainers == [4])
    }

    @Test func undoReopensAfterLastContainerEmptied() {
        let med = Self.trackedMedication(containers: [1], perContainer: 4)
        med.consumeOneUnit() // empties everything
        #expect(med.totalRemaining == 0)
        med.restoreOneUnit() // undo re-opens a container with 1 unit
        #expect(med.supplyContainers == [1])
        #expect(med.currentContainerRemaining == 1)
    }

    @Test func consumingEmptySupplyIsNoOp() {
        let med = Self.trackedMedication(containers: [])
        med.consumeOneUnit()
        #expect(med.totalRemaining == 0)
    }

    @Test func lowSupplyUsesTotalAgainstThreshold() {
        let med = Medication(
            displayName: "Low",
            unitsPerContainer: 4,
            supplyContainers: [1],
            supplyUnitLabel: "doses",
            supplyLowThreshold: 2
        )
        #expect(med.isSupplyLow)
        med.addRefill(quantity: 4)
        #expect(!med.isSupplyLow) // total 5 now exceeds threshold 2
    }
}
