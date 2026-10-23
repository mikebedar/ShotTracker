import Foundation
import SwiftData

enum MedicationKind: String, Codable, CaseIterable, Identifiable {
    case oral
    case injection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oral: "Oral"
        case .injection: "Injection"
        }
    }

    var symbolName: String {
        switch self {
        case .oral: "pills.fill"
        case .injection: "syringe.fill"
        }
    }

    var containerNoun: String {
        switch self {
        case .oral: "bottle"
        case .injection: "vial"
        }
    }
}

enum DoseActionType: String, Codable, CaseIterable, Identifiable {
    case taken
    case skipped
    case snoozed
    case pending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .taken: "Taken"
        case .skipped: "Skipped"
        case .snoozed: "Snoozed"
        case .pending: "Pending"
        }
    }

    /// How a logged event reads in History and the CSV export. Undo is logged as a
    /// `.pending` event, which "Pending" misdescribes.
    var historyTitle: String {
        self == .pending ? "Undone" : title
    }
}

enum DoseStatus: String, Codable, CaseIterable, Identifiable {
    case upcoming
    case due
    case overdue
    case takenOnTime
    case takenLate
    case skipped
    case snoozed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upcoming: "Upcoming"
        case .due: "Due"
        case .overdue: "Overdue"
        case .takenOnTime: "Taken on time"
        case .takenLate: "Taken late"
        case .skipped: "Skipped"
        case .snoozed: "Snoozed"
        }
    }
}

enum ScheduleFrequency: String, Codable, CaseIterable, Identifiable {
    case daily
    case intervalDays
    case weekly
    case monthly
    case cycle
    case phased

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: "Daily"
        case .intervalDays: "Every N days"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .cycle: "Cycle"
        case .phased: "Phased"
        }
    }
}

/// How the schedule responds when a dose is taken late (or missed). Encodes the three
/// real-world clinical patterns: fixed-calendar meds (most oral) vs. interval-maintaining
/// meds (weekly injections) that reschedule the next dose from the actual administration.
enum MissedDosePolicy: String, Codable, CaseIterable, Identifiable {
    case keepToSchedule
    case skipIfLate
    case rescheduleFromLastDose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepToSchedule: "Keep to schedule"
        case .skipIfLate: "Skip if late"
        case .rescheduleFromLastDose: "Reschedule from last dose"
        }
    }

    /// One-line explanation shown under the picker.
    var explanation: String {
        switch self {
        case .keepToSchedule:
            "Take a late dose within the window, otherwise skip it. The next dose stays on its normal day."
        case .skipIfLate:
            "If you miss a dose, wait for the next scheduled one. Best for medications taken several times a day."
        case .rescheduleFromLastDose:
            "Taking a dose sets the schedule forward from that point, keeping a steady interval. Best for weekly injections."
        }
    }

    var symbolName: String {
        switch self {
        case .keepToSchedule: "calendar"
        case .skipIfLate: "forward.end"
        case .rescheduleFromLastDose: "arrow.trianglehead.clockwise"
        }
    }

    static func defaultFor(kind: MedicationKind) -> MissedDosePolicy {
        switch kind {
        case .injection: .rescheduleFromLastDose
        case .oral: .keepToSchedule
        }
    }
}

enum TimingAnchorKind: String, Codable, CaseIterable, Identifiable {
    case exactTime
    case morning
    case noon
    case evening
    case night
    case bedtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exactTime: "Specific time"
        case .morning: "Morning"
        case .noon: "Noon"
        case .evening: "Evening"
        case .night: "Night"
        case .bedtime: "Before bed"
        }
    }

    /// Named slots are flexible time ranges; `.exactTime` is a precise point.
    var isWindow: Bool { self != .exactTime }

    /// Default range for a named slot. `.exactTime` has no window (a point).
    var defaultWindow: DoseWindow? {
        switch self {
        case .exactTime: nil
        case .morning: DoseWindow(start: ClockTime(hour: 6, minute: 0), end: ClockTime(hour: 12, minute: 0))
        case .noon: DoseWindow(start: ClockTime(hour: 11, minute: 0), end: ClockTime(hour: 14, minute: 0))
        case .evening: DoseWindow(start: ClockTime(hour: 17, minute: 0), end: ClockTime(hour: 21, minute: 0))
        case .night: DoseWindow(start: ClockTime(hour: 20, minute: 0), end: ClockTime(hour: 23, minute: 0))
        case .bedtime: DoseWindow(start: ClockTime(hour: 20, minute: 0), end: ClockTime(hour: 23, minute: 30))
        }
    }
}

/// A flexible "anytime between" range for a dose — the reframe of "when" from a single
/// instant to a window. `end` is treated as the same day as `start` (all slots are
/// intra-day; no overnight windows in v1).
struct DoseWindow: Codable, Hashable {
    var start: ClockTime
    var end: ClockTime

    /// Minutes from start to end (clamped ≥ 0).
    var durationMinutes: Int {
        max(0, (end.hour * 60 + end.minute) - (start.hour * 60 + start.minute))
    }
}

struct ClockTime: Codable, Hashable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(0, hour), 23)
        self.minute = min(max(0, minute), 59)
    }

    init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: components.hour ?? 8, minute: components.minute ?? 0)
    }

    var dateComponents: DateComponents {
        DateComponents(hour: hour, minute: minute)
    }

    func applying(to day: Date, calendar: Calendar) -> Date {
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: dayComponents.year,
            month: dayComponents.month,
            day: dayComponents.day,
            hour: hour,
            minute: minute
        )) ?? day
    }

    /// Localized short time ("9:02 AM", "09:02"). Formats a wall-clock time on a fixed
    /// reference day *in the calendar's own time zone* — formatting an offset from the
    /// 1970 epoch (the old approach) read it back in local time, shifting every label by
    /// the UTC offset ("4:02 AM" for a 9:02 dose in New York).
    var displayText: String { displayText() }

    func displayText(calendar: Calendar = .current, locale: Locale = .current) -> String {
        // Jan 1 2001 has no DST transition anywhere, so every wall-clock time exists.
        let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)) ?? .distantPast
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return date.formatted(style)
    }
}

struct DailyTiming: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var kind: TimingAnchorKind
    var exactTime: ClockTime?
    var overrideTime: ClockTime?
    var reminderWindowMinutes: Int
    /// Per-medication override of a named slot's window (nil = use the global slot
    /// window from `AppPreferences`). Ignored for `.exactTime`. Optional so old stored
    /// regimen blobs decode with a missing key (synthesized `Codable` → nil).
    var customWindow: DoseWindow?

    init(
        id: UUID = UUID(),
        kind: TimingAnchorKind,
        exactTime: ClockTime? = nil,
        overrideTime: ClockTime? = nil,
        reminderWindowMinutes: Int = 60,
        customWindow: DoseWindow? = nil
    ) {
        self.id = id
        self.kind = kind
        self.exactTime = exactTime
        self.overrideTime = overrideTime
        self.reminderWindowMinutes = reminderWindowMinutes
        self.customWindow = customWindow
    }

    var title: String {
        if kind == .exactTime, let exactTime {
            return exactTime.displayText
        }

        return kind.title
    }

    /// Stable, locale-independent slot label stored on each `ScheduledDose` and embedded
    /// in its `occurrenceKey`: "morning", "before-bed", or "at-0902" for a specific time.
    /// (It used to be the localized title, so an exact-time label changed with the
    /// locale or 12/24-hour setting — and carried the UTC-offset bug of `displayText`.)
    var slotLabel: String {
        if kind == .exactTime {
            let time = exactTime ?? overrideTime ?? ClockTime(hour: 8, minute: 0)
            return String(format: "at-%02d%02d", time.hour, time.minute)
        }
        return kind.slotLabel
    }
}

extension TimingAnchorKind {
    /// The label a named slot's doses carry ("morning", "before-bed").
    var slotLabel: String {
        title.replacingOccurrences(of: " ", with: "-").lowercased()
    }

    /// Reverse of `slotLabel` for display; nil for exact-time labels.
    init?(slotLabel: String) {
        guard let kind = TimingAnchorKind.allCases.first(where: { $0 != .exactTime && $0.slotLabel == slotLabel }) else {
            return nil
        }
        self = kind
    }
}

/// Human-readable slot names for stored doses. `ScheduledDose.timingLabel` is an
/// identifier, not display text — never `.capitalized` it in a view.
enum SlotTitle {
    /// "Morning", "Before bed", or the dose's time for a precise (exact-time) dose.
    static func title(label: String, scheduledAt: Date, isWindow: Bool, timeZone: TimeZone? = nil) -> String {
        if let kind = TimingAnchorKind(slotLabel: label) {
            return kind.title
        }
        if !isWindow {
            var style = Date.FormatStyle(date: .omitted, time: .shortened)
            style.timeZone = timeZone ?? .autoupdatingCurrent
            return scheduledAt.formatted(style)
        }
        let words = label.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A slot label on its own (no dose), e.g. the adherence card's "most missed".
    static func title(label: String) -> String {
        if let kind = TimingAnchorKind(slotLabel: label) {
            return kind.title
        }
        if label.hasPrefix("at-"), label.count == 7,
           let hour = Int(label.dropFirst(3).prefix(2)), let minute = Int(label.suffix(2)) {
            return ClockTime(hour: hour, minute: minute).displayText
        }
        let words = label.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

nonisolated struct RecurrenceRule: Codable, Hashable {
    var frequency: ScheduleFrequency
    var intervalDays: Int
    var weekdays: [Int]
    var dayOfMonth: Int
    var cycleOnDays: Int
    var cycleOffDays: Int

    init(
        frequency: ScheduleFrequency = .daily,
        intervalDays: Int = 1,
        weekdays: [Int] = [],
        dayOfMonth: Int = 1,
        cycleOnDays: Int = 1,
        cycleOffDays: Int = 0
    ) {
        self.frequency = frequency
        self.intervalDays = max(1, intervalDays)
        self.weekdays = weekdays.sorted()
        self.dayOfMonth = min(max(1, dayOfMonth), 31)
        self.cycleOnDays = max(1, cycleOnDays)
        self.cycleOffDays = max(0, cycleOffDays)
    }
}

/// Cached FDA structured-product-label sections for a medication, fetched from the
/// openFDA drug label API once a specific lookup variant is chosen. Stored as a plain
/// value type (like `RecurrenceRule`) rather than a `@Model` — it's reference data, not
/// an independently-queried entity, so it needs no relationship or Schema registration.
/// Every field is optional: openFDA coverage varies per drug, and a partial/missing
/// record must never block adding or displaying a medication.
struct DrugLabelInfo: Codable, Hashable {
    var rxcui: String?
    var brandName: String?
    var manufacturerName: String?
    var route: String?
    // Named `drugDescription`, not `description` — SwiftData/Core Data reserves
    // `description` (it collides with NSObject's debug-description property) and
    // crashes at container-init time with "Unable to have an Attribute named description"
    // if any @Model or embedded Codable property uses that exact name.
    var drugDescription: [String]?
    var indicationsAndUsage: [String]?
    var warnings: [String]?
    var boxedWarning: [String]?
    var adverseReactions: [String]?
    var fetchedAt: Date?

    var hasContent: Bool {
        [drugDescription, indicationsAndUsage, warnings, boxedWarning, adverseReactions]
            .contains { $0?.isEmpty == false }
    }
}

@Model
final class Medication {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var canonicalName: String?
    var normalizedMedicationCode: String?
    var notes: String
    @Attribute(.externalStorage) var imageData: Data?
    var isActive: Bool
    var createdAt: Date
    var kindRaw: String = MedicationKind.oral.rawValue
    var takeWithFood: Bool = false
    /// nil = inherit the app-wide default; true/false = explicit per-medication override.
    var timeSensitiveNotifications: Bool?
    /// Number of doses/units each container (vial, bottle) holds. Drives the default
    /// refill amount and the current-container display.
    var unitsPerContainer: Int?
    /// Ordered remaining-count per on-hand container; total = sum, current = first.
    /// A refill appends an element; taking a dose draws down the first, dropping it at 0.
    var supplyContainers: [Int]?
    var supplyUnitLabel: String?
    var supplyLowThreshold: Int?
    var lastRefilledAt: Date?
    /// Human-readable strength/form chosen via Lookup (e.g. "500 mg Tab") — the exact
    /// RxCUI lives in `normalizedMedicationCode`, but that alone isn't display-friendly.
    var selectedStrengthAndForm: String?
    var drugLabelInfo: DrugLabelInfo?

    @Relationship(deleteRule: .cascade, inverse: \MedicationRegimen.medication)
    var regimens: [MedicationRegimen]

    @Relationship(deleteRule: .cascade, inverse: \ScheduledDose.medication)
    var scheduledDoses: [ScheduledDose]

    @Relationship(deleteRule: .cascade, inverse: \DoseEvent.medication)
    var doseEvents: [DoseEvent]

    @Relationship(deleteRule: .cascade, inverse: \RefillEvent.medication)
    var refillEvents: [RefillEvent]

    init(
        id: UUID = UUID(),
        displayName: String,
        canonicalName: String? = nil,
        normalizedMedicationCode: String? = nil,
        notes: String = "",
        imageData: Data? = nil,
        isActive: Bool = true,
        createdAt: Date = .now,
        kind: MedicationKind = .oral,
        takeWithFood: Bool = false,
        timeSensitiveNotifications: Bool? = nil,
        unitsPerContainer: Int? = nil,
        supplyContainers: [Int]? = nil,
        supplyUnitLabel: String? = nil,
        supplyLowThreshold: Int? = nil,
        selectedStrengthAndForm: String? = nil,
        drugLabelInfo: DrugLabelInfo? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.canonicalName = canonicalName
        self.normalizedMedicationCode = normalizedMedicationCode
        self.notes = notes
        self.imageData = imageData
        self.isActive = isActive
        self.createdAt = createdAt
        self.kindRaw = kind.rawValue
        self.takeWithFood = takeWithFood
        self.timeSensitiveNotifications = timeSensitiveNotifications
        self.unitsPerContainer = unitsPerContainer
        self.supplyContainers = supplyContainers
        self.supplyUnitLabel = supplyUnitLabel
        self.supplyLowThreshold = supplyLowThreshold
        self.selectedStrengthAndForm = selectedStrengthAndForm
        self.drugLabelInfo = drugLabelInfo
        self.regimens = []
        self.scheduledDoses = []
        self.doseEvents = []
        self.refillEvents = []
    }

    var spokenName: String {
        guard let canonicalName, !canonicalName.isEmpty, canonicalName != displayName else {
            return displayName
        }

        return "\(displayName), also known as \(canonicalName)"
    }

    var kind: MedicationKind {
        get { MedicationKind(rawValue: kindRaw) ?? .oral }
        set { kindRaw = newValue.rawValue }
    }

    /// Deterministic hue (0..<360) used to tint this medication's avatar — mirrors the
    /// source design's per-medication `hue` value. Derived from the UUID's raw bytes
    /// (not `hashValue`, which is randomly seeded per process launch) so the color is
    /// stable across launches without needing a stored color/index field.
    var avatarHue: Double {
        let bytes = id.uuid
        return Double((Int(bytes.0) << 8 | Int(bytes.1)) % 360)
    }

    var isTrackingSupply: Bool {
        supplyUnitLabel?.isEmpty == false && supplyContainers != nil
    }

    /// Units left across every on-hand container.
    var totalRemaining: Int {
        supplyContainers?.reduce(0, +) ?? 0
    }

    /// Units left in the container currently in use (the first non-empty one).
    var currentContainerRemaining: Int {
        supplyContainers?.first(where: { $0 > 0 }) ?? 0
    }

    var effectiveSupplyLowThreshold: Int {
        supplyLowThreshold ?? max(1, (unitsPerContainer ?? totalRemaining) / 5)
    }

    var isSupplyLow: Bool {
        isTrackingSupply && totalRemaining <= effectiveSupplyLowThreshold
    }

    /// The most recent actual administration time — the `completedAt` of the latest dose
    /// marked taken. Drives `.rescheduleFromLastDose` scheduling (the schedule rolls
    /// forward from here). `nil` until the first dose is taken.
    var lastAdministeredAt: Date? {
        lastTakenDose?.completedAt
    }

    /// The dose behind `lastAdministeredAt`.
    var lastTakenDose: ScheduledDose? {
        scheduledDoses
            .filter { $0.lastAction == .taken && $0.completedAt != nil }
            .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }

    /// The time zone a regimen version's times are written in (its "home" zone) — the
    /// given version's, else the active regimen's. nil without a regimen.
    func homeTimeZone(forVersion version: Int? = nil) -> TimeZone? {
        let regimen = version.flatMap { version in regimens.first { $0.version == version } } ?? regimens.active
        return regimen?.homeTimeZone
    }

    /// Draw down one unit from the open container, dropping it when it empties so the
    /// next becomes current. No-op when not tracking or already empty.
    func consumeOneUnit() {
        guard var containers = supplyContainers else { return }
        guard let index = containers.firstIndex(where: { $0 > 0 }) else { return }
        containers[index] -= 1
        containers.removeAll { $0 <= 0 }
        supplyContainers = containers
    }

    /// Restore one unit (the Undo path) back into the current container, or re-open a
    /// container if they'd all been emptied.
    func restoreOneUnit() {
        guard isTrackingSupply else { return }
        var containers = supplyContainers ?? []
        if let index = containers.firstIndex(where: { $0 > 0 }) {
            containers[index] += 1
        } else {
            containers.insert(1, at: 0)
        }
        supplyContainers = containers
    }

    /// Log a refill: append `quantity` units as a new container behind any still in use.
    func addRefill(quantity: Int, at date: Date = .now) {
        guard quantity > 0 else { return }
        var containers = supplyContainers ?? []
        containers.append(quantity)
        supplyContainers = containers
        lastRefilledAt = date
    }
}

@Model
final class MedicationRegimen {
    @Attribute(.unique) var id: UUID
    var version: Int
    var anchorDate: Date
    var timeZoneIdentifier: String
    var recurrenceRule: RecurrenceRule
    var timings: [DailyTiming]
    var graceWindowMinutes: Int
    var isActive: Bool
    var createdAt: Date
    var missedDosePolicyRaw: String = MissedDosePolicy.keepToSchedule.rawValue
    /// Minimum gap (hours) enforced between actual doses under `.rescheduleFromLastDose`.
    /// nil = derive `defaultMinimumIntervalHours` from the recurrence interval.
    var minimumIntervalHours: Int?

    var medication: Medication?

    @Relationship(deleteRule: .cascade, inverse: \RegimenPhase.regimen)
    var phases: [RegimenPhase]

    @Relationship(deleteRule: .cascade, inverse: \ReminderPolicy.regimen)
    var reminderPolicies: [ReminderPolicy]

    init(
        id: UUID = UUID(),
        version: Int = 1,
        anchorDate: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        recurrenceRule: RecurrenceRule = RecurrenceRule(),
        timings: [DailyTiming] = [DailyTiming(kind: .morning)],
        graceWindowMinutes: Int = 180,
        isActive: Bool = true,
        createdAt: Date = .now,
        missedDosePolicy: MissedDosePolicy = .keepToSchedule,
        minimumIntervalHours: Int? = nil,
        medication: Medication? = nil
    ) {
        self.id = id
        self.version = version
        self.anchorDate = anchorDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.recurrenceRule = recurrenceRule
        self.timings = timings
        self.graceWindowMinutes = graceWindowMinutes
        self.isActive = isActive
        self.createdAt = createdAt
        self.missedDosePolicyRaw = missedDosePolicy.rawValue
        self.minimumIntervalHours = minimumIntervalHours
        self.medication = medication
        self.phases = []
        self.reminderPolicies = []
    }

    var activeReminderPolicy: ReminderPolicy? {
        reminderPolicies.sorted(by: { $0.createdAt > $1.createdAt }).first
    }

    /// The zone this version's clock times live in (`timeZoneIdentifier`): set from the
    /// device when the schedule is created, kept when the user travels, changed only by
    /// an edit (which creates a new version).
    var homeTimeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    var missedDosePolicy: MissedDosePolicy {
        get { MissedDosePolicy(rawValue: missedDosePolicyRaw) ?? .keepToSchedule }
        set { missedDosePolicyRaw = newValue.rawValue }
    }

    /// The nominal spacing between doses, used to roll the schedule forward from the last
    /// actual dose. `nil` for `.cycle`/`.phased` (their on/off & phase math isn't a single
    /// interval) — rolling falls back to fixed behavior for those.
    var nominalIntervalComponents: DateComponents? {
        switch recurrenceRule.frequency {
        case .daily: DateComponents(day: 1)
        case .intervalDays: DateComponents(day: max(1, recurrenceRule.intervalDays))
        case .weekly: DateComponents(day: 7)
        case .monthly: DateComponents(month: 1)
        case .cycle, .phased: nil
        }
    }

    /// Default minimum gap between doses for rolling meds: half the nominal interval,
    /// clamped to 1–3 days. Weekly → 72h (3d), every-3-days → 36h, daily → 24h.
    var defaultMinimumIntervalHours: Int {
        let nominalHours: Int
        switch recurrenceRule.frequency {
        case .daily: nominalHours = 24
        case .intervalDays: nominalHours = max(1, recurrenceRule.intervalDays) * 24
        case .weekly: nominalHours = 7 * 24
        case .monthly: nominalHours = 30 * 24
        case .cycle, .phased: nominalHours = 24
        }
        return min(max(nominalHours / 2, 24), 72)
    }

    var effectiveMinimumIntervalHours: Int {
        minimumIntervalHours ?? defaultMinimumIntervalHours
    }
}

@Model
final class RegimenPhase {
    @Attribute(.unique) var id: UUID
    var title: String
    var startDayOffset: Int
    var durationDays: Int?
    var recurrenceRule: RecurrenceRule
    var timings: [DailyTiming]

    var regimen: MedicationRegimen?

    init(
        id: UUID = UUID(),
        title: String,
        startDayOffset: Int,
        durationDays: Int? = nil,
        recurrenceRule: RecurrenceRule,
        timings: [DailyTiming]
    ) {
        self.id = id
        self.title = title
        self.startDayOffset = startDayOffset
        self.durationDays = durationDays
        self.recurrenceRule = recurrenceRule
        self.timings = timings
    }
}

@Model
final class ReminderPolicy {
    @Attribute(.unique) var id: UUID
    var isEnabled: Bool
    var dueRemindersEnabled: Bool
    var overdueRemindersEnabled: Bool
    var playSound: Bool
    var allowSnooze: Bool
    var defaultSnoozeMinutes: Int
    var maxReminderCount: Int
    var escalationIntervalsMinutes: [Int]
    var routineSlotReminderWindowMinutes: Int
    var createdAt: Date

    var regimen: MedicationRegimen?

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        dueRemindersEnabled: Bool = true,
        overdueRemindersEnabled: Bool = true,
        playSound: Bool = true,
        allowSnooze: Bool = true,
        defaultSnoozeMinutes: Int = 20,
        maxReminderCount: Int = 6,
        escalationIntervalsMinutes: [Int] = [0, 30, 120, 720, 1440],
        routineSlotReminderWindowMinutes: Int = 90,
        createdAt: Date = .now
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.dueRemindersEnabled = dueRemindersEnabled
        self.overdueRemindersEnabled = overdueRemindersEnabled
        self.playSound = playSound
        self.allowSnooze = allowSnooze
        self.defaultSnoozeMinutes = defaultSnoozeMinutes
        self.maxReminderCount = maxReminderCount
        self.escalationIntervalsMinutes = escalationIntervalsMinutes
        self.routineSlotReminderWindowMinutes = routineSlotReminderWindowMinutes
        self.createdAt = createdAt
    }
}

@Model
final class ScheduledDose {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var occurrenceKey: String
    var regimenVersion: Int
    var scheduledAt: Date
    var timingLabel: String
    var reminderWindowMinutes: Int
    var graceWindowMinutes: Int
    /// Latest time this dose is still "on time." nil = a precise (exact-time) dose, which
    /// falls back to `scheduledAt + graceWindowMinutes`. For a flexible slot, `scheduledAt`
    /// is the window start and this is the window end.
    var windowEndAt: Date?
    /// When the reminder should fire (near a window's close, or the exact time for a
    /// point). nil = fall back to `scheduledAt`.
    var reminderAt: Date?
    var statusRaw: String
    var lastActionRaw: String
    var completedAt: Date?
    var snoozedUntil: Date?
    var generatedAt: Date
    /// The `DailyTiming.id` this dose was generated from — the slot's identity across
    /// regimen versions and key changes, so a refresh can recognise "today's morning dose"
    /// even after its key changed. nil on rows written before this existed.
    var timingID: UUID?
    /// Total minutes this dose has been snoozed (every snooze adds its length; undoing a
    /// snooze takes its minutes back off). The deadline moves by this much — nothing else
    /// does: on time vs late is still judged against the original window. nil on rows
    /// written before snoozes were tracked = 0.
    var snoozeOffsetMinutes: Int?

    var medication: Medication?

    @Relationship(deleteRule: .cascade, inverse: \DoseEvent.scheduledDose)
    var events: [DoseEvent]

    init(
        id: UUID = UUID(),
        occurrenceKey: String,
        regimenVersion: Int,
        scheduledAt: Date,
        timingLabel: String,
        reminderWindowMinutes: Int,
        graceWindowMinutes: Int,
        windowEndAt: Date? = nil,
        reminderAt: Date? = nil,
        status: DoseStatus = .upcoming,
        lastAction: DoseActionType = .pending,
        medication: Medication? = nil,
        generatedAt: Date = .now,
        timingID: UUID? = nil
    ) {
        self.id = id
        self.timingID = timingID
        self.occurrenceKey = occurrenceKey
        self.regimenVersion = regimenVersion
        self.scheduledAt = scheduledAt
        self.timingLabel = timingLabel
        self.reminderWindowMinutes = reminderWindowMinutes
        self.graceWindowMinutes = graceWindowMinutes
        self.windowEndAt = windowEndAt
        self.reminderAt = reminderAt
        self.statusRaw = status.rawValue
        self.lastActionRaw = lastAction.rawValue
        self.completedAt = nil
        self.snoozedUntil = nil
        self.medication = medication
        self.generatedAt = generatedAt
        self.events = []
    }

    var status: DoseStatus {
        get { DoseStatus(rawValue: statusRaw) ?? .upcoming }
        set { statusRaw = newValue.rawValue }
    }

    var lastAction: DoseActionType {
        get { DoseActionType(rawValue: lastActionRaw) ?? .pending }
        set { lastActionRaw = newValue.rawValue }
    }

    /// Earliest "on time" instant (the window start). Same as `scheduledAt`.
    var windowStart: Date { scheduledAt }

    /// Latest "on time" instant. A flexible dose uses its stored window end; a precise
    /// (exact-time) dose falls back to the scheduled time plus its grace window.
    var windowEnd: Date {
        windowEndAt ?? scheduledAt.addingTimeInterval(TimeInterval(graceWindowMinutes * 60))
    }

    /// True when this dose spans a real range rather than a single instant + grace.
    var isFlexibleWindow: Bool { windowEndAt != nil }

    /// Cumulative snooze, in minutes (0 when never snoozed or on pre-tracking rows).
    var snoozeOffset: Int { max(0, snoozeOffsetMinutes ?? 0) }

    /// When the dose turns overdue: the original window end plus the snooze offset. A
    /// snooze used to move both window bounds to the snooze end, so a morning dose snoozed
    /// at 10:00 stayed "on time" until ~16:20; now only this dose's deadline moves, by
    /// exactly the snoozed minutes.
    var deadline: Date {
        windowEnd.addingTimeInterval(TimeInterval(snoozeOffset * 60))
    }

    /// Minutes past the original window end a taken dose was logged (0 when on time).
    var minutesLate: Int {
        guard let completedAt, lastAction == .taken else { return 0 }
        return max(0, Int((completedAt.timeIntervalSince(windowEnd) / 60).rounded(.up)))
    }

    /// "Morning", "Before bed", or "9:02 AM" — see `SlotTitle`. A precise dose's time
    /// reads on its home clock (the time the user scheduled).
    var slotTitle: String {
        SlotTitle.title(label: timingLabel, scheduledAt: scheduledAt, isWindow: isFlexibleWindow, timeZone: homeTimeZone)
    }

    /// The home zone of the regimen version that generated this dose. nil for a
    /// transient (forecast) dose, which has no medication attached — callers that have
    /// the medication use `Medication.homeTimeZone(forVersion:)`.
    var homeTimeZone: TimeZone? {
        medication?.homeTimeZone(forVersion: regimenVersion)
    }

    /// Never acted on: no completion and no logged events. Only untouched rows are ever
    /// pruned or re-keyed freely by `DoseRepository.refreshSchedules`.
    var isUntouched: Bool { completedAt == nil && events.isEmpty }
}

@Model
final class DoseEvent {
    @Attribute(.unique) var id: UUID
    var loggedAt: Date
    var actionRaw: String
    var note: String
    /// For a snooze: the minutes this snooze added. nil for other actions and old rows.
    var snoozeMinutes: Int?
    /// The dose's cumulative snooze offset once this event applied — so history and the
    /// CSV can say "taken 45 min late · snoozed 30 min" even after the dose row changes
    /// or is gone. nil on old rows = 0.
    var snoozeOffsetMinutes: Int?
    /// For a taken dose: minutes past the original window end (0 = on time). nil for other
    /// actions and old rows.
    var minutesLate: Int?

    var medication: Medication?
    var scheduledDose: ScheduledDose?

    init(
        id: UUID = UUID(),
        loggedAt: Date = .now,
        action: DoseActionType,
        note: String = "",
        snoozeMinutes: Int? = nil,
        snoozeOffsetMinutes: Int? = nil,
        minutesLate: Int? = nil,
        medication: Medication? = nil,
        scheduledDose: ScheduledDose? = nil
    ) {
        self.id = id
        self.loggedAt = loggedAt
        self.actionRaw = action.rawValue
        self.note = note
        self.snoozeMinutes = snoozeMinutes
        self.snoozeOffsetMinutes = snoozeOffsetMinutes
        self.minutesLate = minutesLate
        self.medication = medication
        self.scheduledDose = scheduledDose
    }

    var action: DoseActionType {
        get { DoseActionType(rawValue: actionRaw) ?? .pending }
        set { actionRaw = newValue.rawValue }
    }
}

@Model
final class RefillEvent {
    @Attribute(.unique) var id: UUID
    var loggedAt: Date
    var quantity: Int
    var note: String

    var medication: Medication?

    init(
        id: UUID = UUID(),
        loggedAt: Date = .now,
        quantity: Int,
        note: String = "",
        medication: Medication? = nil
    ) {
        self.id = id
        self.loggedAt = loggedAt
        self.quantity = quantity
        self.note = note
        self.medication = medication
    }
}

extension Array where Element == MedicationRegimen {
    var active: MedicationRegimen? {
        self
            .filter(\.isActive)
            .sorted(by: { lhs, rhs in
                if lhs.version == rhs.version {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.version > rhs.version
            })
            .first
    }
}
