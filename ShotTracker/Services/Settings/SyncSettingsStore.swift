import Foundation
import Observation

@MainActor
@Observable
final class SyncSettingsStore {
    static let shared = SyncSettingsStore()

    private let defaults = UserDefaults.standard
    private let syncKey = "medicationTracker.syncEnabled"

    var isICloudSyncEnabled: Bool {
        didSet {
            defaults.set(isICloudSyncEnabled, forKey: syncKey)
        }
    }

    private init() {
        isICloudSyncEnabled = defaults.bool(forKey: syncKey)
    }
}
