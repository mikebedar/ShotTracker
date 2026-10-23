import Foundation

/// Shared between the app and the widget extension. This file is intentionally
/// self-contained — it must compile into the widget target, which does **not** link
/// SwiftData or the `@Model` types. It therefore does not reference `DoseStatus`,
/// `ScheduledDose`, or any app model; it carries plain values the app writes and the
/// widget reads.

// MARK: - App Group plumbing

enum WidgetShared {
    /// Must match the `com.apple.security.application-groups` entry in both the app's and
    /// the widget's entitlements.
    static let appGroupID = "group.bedar.net.ShotTracker"
    static let snapshotFileName = "today-snapshot.json"
    /// The custom URL a widget tap opens; handled in the app via `.onOpenURL`.
    static let deepLinkScheme = "shottracker"
    static let todayDeepLink = URL(string: "shottracker://today")!

    /// Location of the shared snapshot inside the App Group container. `nil` if the group
    /// container is unavailable (e.g. entitlement not yet provisioned).
    static func snapshotURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(snapshotFileName)
    }
}

// MARK: - Status

/// A value-type mirror of the app's `DoseStatus`, with identical raw values so the two
/// convert 1:1 by `rawValue`. Kept here so the widget can render/resolve status without
/// the app model.
enum WidgetDoseStatus: String, Codable {
    case upcoming, due, overdue, takenOnTime, takenLate, skipped, snoozed

    var isResolved: Bool {
        switch self {
        case .takenOnTime, .takenLate, .skipped: true
        case .upcoming, .due, .overdue, .snoozed: false
        }
    }

    var isOverdue: Bool { self == .overdue }
}

// MARK: - Snapshot

struct TodayWidgetSnapshot: Codable {
    var generatedAt: Date
    var showMedicationNames: Bool
    /// Already ordered for display: overdue first, then upcoming-today. Capped by the writer.
    var items: [WidgetDoseItem]

    static let empty = TodayWidgetSnapshot(generatedAt: .distantPast, showMedicationNames: true, items: [])

    /// The items that belong on the widget at `date`: nothing from a later day, nothing
    /// resolved, and no missed dose from an earlier day that a later dose of the same
    /// medication has replaced (mirrors `DoseSupersession` in the app).
    func items(relevantAt date: Date, calendar: Calendar = .current) -> [WidgetDoseItem] {
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date
        var latestStarted: [String: Date] = [:]
        for item in items where item.scheduledAt <= date {
            guard let id = item.medicationID else { continue }
            latestStarted[id] = max(latestStarted[id] ?? .distantPast, item.scheduledAt)
        }
        return items.filter { item in
            guard item.scheduledAt < endOfDay, !item.resolvedStatus(now: date).isResolved else { return false }
            if item.scheduledAt < startOfDay, let id = item.medicationID, let latest = latestStarted[id], latest > item.scheduledAt {
                return false
            }
            return true
        }
    }
}

struct WidgetDoseItem: Codable, Identifiable {
    var occurrenceKey: String
    /// Groups a medication's items (an earlier missed dose is hidden once a later one of
    /// the same medication comes due). Optional so older snapshots still decode.
    var medicationID: String? = nil
    var displayName: String
    /// SF Symbol for the medication kind (used in discreet mode instead of the name/initial).
    var kindSymbol: String
    var avatarHue: Double
    var takeWithFood: Bool
    var timingLabel: String

    // Raw timing/state carried so the widget can re-resolve status between app writes
    // (e.g. a dose flips upcoming → due → overdue as the day advances).
    var scheduledAt: Date      // window start
    var windowEnd: Date        // window end (already grace-adjusted for exact-time doses)
    var isFlexibleWindow: Bool // true = a real range ("anytime by …"); false = a precise time
    var snoozedUntil: Date?
    var isTaken: Bool
    var isSkipped: Bool
    /// `DoseStatus.rawValue` stored on the dose — used for taken-on-time vs taken-late.
    var storedStatus: String

    var id: String { occurrenceKey }

    /// The medication's first character, uppercased — for the letter avatar. Empty → "?".
    var avatarLetter: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).first
            .map { String($0).uppercased() } ?? "?"
    }

    /// Glanceable timing phrase: a flexible dose reads "by <window end>"; a precise dose
    /// shows its exact time.
    var timeText: String {
        if isFlexibleWindow {
            return "by " + windowEnd.formatted(date: .omitted, time: .shortened)
        }
        return scheduledAt.formatted(date: .omitted, time: .shortened)
    }

    /// Mirrors `DoseStatusEvaluator.effectiveStatus(for:now:)` exactly. **Keep in sync with
    /// that method** — the `WidgetStatusParityTests` suite guards the two against drift.
    func resolvedStatus(now: Date = .now) -> WidgetDoseStatus {
        if isSkipped { return .skipped }
        if isTaken { return WidgetDoseStatus(rawValue: storedStatus) ?? .takenOnTime }

        if let snoozedUntil, snoozedUntil > now { return .snoozed }

        // A snooze pushes both bounds of the (possibly flexible) window forward.
        let windowStart = snoozedUntil ?? scheduledAt
        let resolvedEnd = snoozedUntil.map { $0.addingTimeInterval(windowEnd.timeIntervalSince(scheduledAt)) } ?? windowEnd

        if now < windowStart { return .upcoming }
        if now <= resolvedEnd { return .due }
        return .overdue
    }
}
