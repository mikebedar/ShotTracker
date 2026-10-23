import Foundation
import SwiftData

enum MedicationModelContainer {
    @MainActor
    static func makeSharedContainer() throws -> ModelContainer {
        let schema = Schema([
            Medication.self,
            MedicationRegimen.self,
            RegimenPhase.self,
            ReminderPolicy.self,
            ScheduledDose.self,
            DoseEvent.self,
            RefillEvent.self,
        ])

        let fileManager = FileManager.default
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try fileManager.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)

        // Keep the default SwiftData store filename so existing simulator data remains readable.
        let storeURL = applicationSupportURL.appending(path: "default.store")
        let configuration = ModelConfiguration(url: storeURL)

        return try ModelContainer(for: schema, configurations: configuration)
    }
}
