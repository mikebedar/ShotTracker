import Foundation
import SwiftData

enum MedicationModelContainer {
    /// `inMemory` backs UI tests and previews: a fresh, empty store per launch that never
    /// touches `default.store`.
    @MainActor
    static func makeSharedContainer(inMemory: Bool = LaunchOptions.isUITesting) throws -> ModelContainer {
        let schema = Schema([
            Medication.self,
            MedicationRegimen.self,
            RegimenPhase.self,
            ReminderPolicy.self,
            ScheduledDose.self,
            DoseEvent.self,
            RefillEvent.self,
        ])

        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }

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
