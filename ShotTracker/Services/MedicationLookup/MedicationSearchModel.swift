import Foundation
import Observation

@MainActor
@Observable
final class MedicationSearchModel {
    var query = ""
    var results: [MedicationLookupResult] = []
    var isSearching = false
    var errorMessage: String?

    private let lookupService: MedicationLookupService

    init(lookupService: MedicationLookupService) {
        self.lookupService = lookupService
    }

    func updateQuery(_ value: String) async {
        query = value
        await search()
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            errorMessage = nil
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            results = try await lookupService.search(query: trimmed)
            errorMessage = results.isEmpty ? "No matches found. You can still enter the medication manually." : nil
        } catch {
            results = []
            errorMessage = "Search is unavailable right now. Manual entry still works."
        }
    }

    func clear() {
        query = ""
        results = []
        errorMessage = nil
    }
}
