import SwiftUI

extension AppPreferences {
    /// The routine windows (Settings → Routine Windows) as parts of the day, for naming
    /// the other clock of a dose away from home ("Home: Night").
    var dayParts: DayParts {
        let kinds: [TimingAnchorKind] = [.morning, .noon, .evening, .night]
        return DayParts(windows: kinds.compactMap { kind in
            guard let window = defaultSlotWindows[kind.rawValue] ?? kind.defaultWindow else { return nil }
            return DayPart(
                name: kind.title,
                startMinute: window.start.hour * 60 + window.start.minute,
                endMinute: window.end.hour * 60 + window.end.minute
            )
        })
    }
}

extension EnvironmentValues {
    /// Parts of the day from the routine windows; `AppRootView` sets it from preferences
    /// so presentational components don't read `AppDependencies`.
    @Entry var dayParts: DayParts = .standard
}

/// How one dose's times read, wherever the device is (decided 2026-10-23).
///
/// - A named slot ("Morning") names its clock when away from home — "Morning (Paris)"
///   for one that follows the device, "Morning (home)" for one kept on home time — and
///   the other clock in `detail`: "Home: Night · 2:00 AM", "Here: Afternoon · 2:00 PM".
///   Its times read on its own clock. At home: "Morning", as before.
/// - A specific time keeps "8:00 AM home · 2:00 PM here" (`ZonedTimeFormatter`).
///
/// `times` is for everything else on the dose (logged at, snooze reminder): the device's
/// clock alone for a slot that follows it, else home and here.
struct DoseClockText {
    let slot: SlotClockLabel?
    let times: ZonedTimeFormatter

    /// `medication` is needed for a forecast dose (no relationship); `device` is where the
    /// device is — or, for history, where the dose was logged.
    init(
        dose: ScheduledDose,
        medication: Medication? = nil,
        dayParts: DayParts,
        device: TimeZone = .current,
        locale: Locale = .current
    ) {
        let home = (medication ?? dose.medication)?.homeTimeZone(forVersion: dose.regimenVersion)
        let clock = dose.clockTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? home
        if dose.isFlexibleWindow {
            let label = SlotClockLabel(
                slotTitle: dose.slotTitle,
                windowStart: dose.scheduledAt,
                windowEnd: dose.windowEnd,
                clock: clock,
                home: home,
                device: device,
                dayParts: dayParts,
                locale: locale
            )
            slot = label
            if case .followsDevice = label.placement {
                times = ZonedTimeFormatter(home: device, local: device, locale: locale)
            } else {
                times = ZonedTimeFormatter(home: home, local: device, locale: locale)
            }
        } else {
            slot = nil
            times = ZonedTimeFormatter(home: home, local: device, locale: locale)
        }
    }

    /// A slot whose label says more than its name (away from home).
    var awaySlot: SlotClockLabel? {
        slot.flatMap { $0.isOneClock ? nil : $0 }
    }

    /// A dose's time in a list: "6:00 AM" at home, "Morning (Paris) · 6:00 AM" for a slot
    /// away from home, "8:00 AM home · 2:00 PM here" for a specific time.
    func point(_ date: Date) -> String {
        guard let slot = awaySlot else { return times.time(date) }
        return String(localized: "\(slot.title) · \(slot.time(date))", comment: "A dose slot named with its clock and its time, e.g. Morning (Paris) · 6:00 AM")
    }

    /// `point` with a date: "Oct 23, 2026 at 6:00 AM", "Morning (Paris) · Oct 23, 2026 at 6:00 AM".
    func pointWithDate(_ date: Date) -> String {
        guard let slot = awaySlot else { return times.dateTime(date) }
        return String(localized: "\(slot.title) · \(slot.dateTime(date))", comment: "A dose slot named with its clock, its date and time")
    }

    /// Spoken `point`: "6:00 AM", "Morning in Paris, 6:00 AM; at home it's night, 12:00 AM".
    func spokenPoint(_ date: Date) -> String {
        guard let slot = awaySlot else { return times.spokenTime(date) }
        return spoken(slot: slot, time: slot.time(date), detail: slot.spokenDetail(date))
    }

    /// The other clock for a slot away from home: "Home: Night · 12:00 AM". nil otherwise.
    func detail(_ date: Date, by: Bool = false) -> String? {
        awaySlot?.detail(date, by: by)
    }

    /// "Morning in Paris, anytime by 12:00 PM; at home it's night, by 6:00 AM."
    func spoken(slot: SlotClockLabel, time: String, detail: String?) -> String {
        let head = String(localized: "\(slot.spokenTitle), \(time)", comment: "Spoken dose slot with its clock and a time")
        guard let detail else { return head }
        return String(localized: "\(head); \(detail)", comment: "Spoken dose slot and the other clock, e.g. Morning in Paris, 6:00 AM; at home it's night, 12:00 AM")
    }
}
