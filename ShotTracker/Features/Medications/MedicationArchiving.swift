import Atelier
import SwiftData
import SwiftUI

/// Deleting a medication is an archive (its history stays), so it is undoable: the toast's Undo (or shake to undo)
/// reactivates it, and Reactivate in Archived offers the reverse. It used to sit behind a confirmation alert.
@MainActor
enum MedicationArchiving {
    static func archive(_ medication: Medication, presenter: Presenter, dependencies: AppDependencies,
                        context: ModelContext) {
        let name = medication.displayName
        presenter.perform(verbatim: "Archived \(name)", actionName: "Delete \(name)") {
            try dependencies.archive(medication, context: context)
            DoseUndoLedger.shared.push(nil)
        } undo: {
            DoseUndoLedger.shared.pop()
            guard medication.modelContext != nil, !medication.isActive else { return }
            do {
                try dependencies.unarchive(medication, context: context)
            } catch {
                presenter.report(error, origin: .userAction)
            }
        }
    }

    static func reactivate(_ medication: Medication, presenter: Presenter, dependencies: AppDependencies,
                           context: ModelContext) {
        let name = medication.displayName
        presenter.perform(verbatim: "Reactivated \(name)", actionName: "Reactivate \(name)") {
            try dependencies.unarchive(medication, context: context)
            DoseUndoLedger.shared.push(nil)
        } undo: {
            DoseUndoLedger.shared.pop()
            guard medication.modelContext != nil, medication.isActive else { return }
            do {
                try dependencies.archive(medication, context: context)
            } catch {
                presenter.report(error, origin: .userAction)
            }
        }
    }
}
