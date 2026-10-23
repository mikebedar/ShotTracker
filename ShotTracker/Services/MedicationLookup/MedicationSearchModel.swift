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

    /// Runs from `.task(id: query)`, which cancels the previous keystroke's task. The
    /// short debounce means one request per pause in typing rather than per character,
    /// and a cancelled request is ignored — it used to land in `catch` and flash
    /// "Search is unavailable" (and wipe the results) on every keystroke.
    func search(debounce: Duration = .milliseconds(300)) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            errorMessage = nil
            return
        }

        do {
            try await Task.sleep(for: debounce)
        } catch {
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            let found = try await lookupService.search(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            errorMessage = found.isEmpty ? "No matches found. You can still enter the medication manually." : nil
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return
            }
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
