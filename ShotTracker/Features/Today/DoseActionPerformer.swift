import Atelier
import SwiftData
import SwiftUI

/// Take / Snooze / Skip (and the card's Undo) as every screen performs them: through `AppDependencies.recordDoseAction`
/// (repository mutation + event, then the full re-plan: notifications and widget), with a toast that offers Undo,
/// registered on the window's `UndoManager` (shake to undo), and the haptic the screen plays.
///
/// Undo is `recordDoseAction(.pending)`, the same path as the card's own Undo button, so mutation, event log and
/// reschedule stay together. It only acts while the dose's last action is still the one it undoes (the card's Undo or
/// a notification action may have got there first).
@MainActor
struct DoseActionPerformer {
    let presenter: Presenter
    let dependencies: AppDependencies
    let context: ModelContext
    let undoManager: UndoManager?

    /// A dose action the repository refused (logged by `AppDependencies`).
    struct NotRecorded: LocalizedError {
        let name: String
        var errorDescription: String? { "Couldn't update \(name)." }
        var recoverySuggestion: String? { "Try again. If it keeps happening, restart ShotTracker." }
    }

    /// Performs `action` and returns the haptic for it (nil when nothing happened).
    @discardableResult
    func perform(_ action: DoseActionType, on dose: ScheduledDose) -> FeedbackRole? {
        let name = dose.medication?.displayName ?? "dose"
        var recorded = false
        presenter.perform(verbatim: title(for: action, dose: dose, name: name),
                          actionName: actionName(for: action, name: name)) {
            guard dependencies.recordDoseAction(action, dose: dose, context: context) else { throw NotRecorded(name: name) }
            recorded = true
            DoseUndoLedger.shared.push(dose.id)
        } undo: { [dependencies, context] in
            DoseUndoLedger.shared.pop()
            guard dose.modelContext != nil, !dose.isDeleted, dose.lastAction == action else { return }
            dependencies.recordDoseAction(.pending, dose: dose, context: context)
        }
        guard recorded else { return .error }
        return Self.feedback(for: action)
    }

    /// The card's Undo: the window's undo when this dose's action is the one on top (so the toast and shake-to-undo
    /// agree), else the same `.pending` action directly. Says what it did in a toast.
    @discardableResult
    func undo(_ dose: ScheduledDose) -> FeedbackRole? {
        let name = dose.medication?.displayName ?? "dose"
        let wasSnooze = dose.lastAction == .snoozed
        if let undoManager, undoManager.canUndo, DoseUndoLedger.shared.top == dose.id {
            undoManager.undo()
        } else {
            guard dependencies.recordDoseAction(.pending, dose: dose, context: context) else {
                presenter.report(NotRecorded(name: name), origin: .userAction)
                return .error
            }
        }
        presenter.toast(Toast(verbatim: wasSnooze ? "Took back the snooze on \(name)" : "Undid \(name)"))
        return .impactLight
    }

    private func title(for action: DoseActionType, dose: ScheduledDose, name: String) -> String {
        switch action {
        case .taken: return "Marked \(name) as taken"
        case .skipped: return "Skipped \(name)"
        case .snoozed:
            let minutes = dose.medication?.regimens.active?.activeReminderPolicy?.defaultSnoozeMinutes ?? 20
            return "Snoozed \(name) \(SnoozeWording.duration(minutes: minutes))"
        case .pending: return "Undid \(name)"
        }
    }

    /// What Undo is called on the iPad's Edit menu ("Undo Take Metformin").
    private func actionName(for action: DoseActionType, name: String) -> String {
        switch action {
        case .taken: "Take \(name)"
        case .skipped: "Skip \(name)"
        case .snoozed: "Snooze \(name)"
        case .pending: "Undo \(name)"
        }
    }

    /// Take is a success, Skip a warning (a missed dose), Snooze a light tap.
    static func feedback(for action: DoseActionType) -> FeedbackRole {
        switch action {
        case .taken: .success
        case .skipped: .warning
        case .snoozed, .pending: .impactLight
        }
    }
}

/// Which dose each of the app's undo registrations belongs to, newest last, so the card's Undo can tell whether the
/// window's next undo is its own (two doses of one medication have the same action name).
@MainActor
final class DoseUndoLedger {
    static let shared = DoseUndoLedger()
    private var entries: [UUID?] = []

    var top: UUID? { entries.last ?? nil }

    /// A dose action was registered (nil: something else, an archive).
    func push(_ doseID: UUID?) { entries.append(doseID) }

    /// Its undo ran.
    func pop() { if !entries.isEmpty { entries.removeLast() } }
}

/// A haptic to play, as state: a screen sets it after an action and `.feedback(trigger:)` plays it.
struct FeedbackPulse: Equatable {
    let id = UUID()
    let role: FeedbackRole
}

extension View {
    /// Plays `pulse`'s role through Atelier's feedback (the theme's haptics, Settings → Appearance → Haptics).
    func feedback(_ pulse: FeedbackPulse?) -> some View {
        feedback(trigger: pulse) { _, new in new?.role }
    }
}

extension Confirmation {
    /// "Take dose early?" before a rolling dose inside its minimum interval (`DoseRescheduling.minimumIntervalWarning`).
    /// An alert: the message is something to read before going on.
    static func takeEarly(_ message: String) -> Confirmation {
        Confirmation(verbatim: "Take dose early?", message: message, confirmTitle: "Take Anyway", style: .alert)
    }
}
