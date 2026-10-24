import Foundation

/// A named part of the day and the clock range it covers, in minutes after midnight.
nonisolated struct DayPart: Codable, Hashable {
    var name: String
    var startMinute: Int
    var endMinute: Int
}

/// Names a clock time by part of day — "Night", "Afternoon" — for the other clock of a
/// dose away from home ("Home: Night · 2:00 AM"). The routine windows come first
/// (Settings → Routine Windows: morning, noon, evening, night); where none covers the
/// time, a plain division of the day does (night, morning, afternoon, evening).
///
/// Compiled into the app and the widget (plain values; the app builds it from its
/// preferences, `AppPreferences.dayParts`, and the widget snapshot carries a copy).
nonisolated struct DayParts: Codable, Hashable {
    var windows: [DayPart]

    /// The default routine windows (used when no preferences are at hand).
    static let standard = DayParts(windows: [
        DayPart(name: String(localized: "Morning", comment: "Part of the day"), startMinute: 6 * 60, endMinute: 12 * 60),
        DayPart(name: String(localized: "Noon", comment: "Part of the day"), startMinute: 11 * 60, endMinute: 14 * 60),
        DayPart(name: String(localized: "Evening", comment: "Part of the day"), startMinute: 17 * 60, endMinute: 21 * 60),
        DayPart(name: String(localized: "Night", comment: "Part of the day"), startMinute: 20 * 60, endMinute: 23 * 60),
    ])

    /// The part of day `minute` (0..<1440) falls in: the routine window that contains it
    /// (the one whose middle is nearest when two overlap: 11:30 is noon, 20:30 night),
    /// else night / morning / afternoon / evening.
    func name(forMinute minute: Int) -> String {
        let containing = windows.filter { $0.startMinute <= minute && minute < $0.endMinute }
        if let best = containing.min(by: { distance($0, minute) < distance($1, minute) }) {
            return best.name
        }
        switch minute {
        case ..<(5 * 60): return String(localized: "Night", comment: "Part of the day")
        case ..<(12 * 60): return String(localized: "Morning", comment: "Part of the day")
        case ..<(17 * 60): return String(localized: "Afternoon", comment: "Part of the day")
        case ..<(21 * 60): return String(localized: "Evening", comment: "Part of the day")
        default: return String(localized: "Night", comment: "Part of the day")
        }
    }

    /// The part of day `date` falls in on `zone`'s clock.
    func name(at date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return name(forMinute: (components.hour ?? 0) * 60 + (components.minute ?? 0))
    }

    private func distance(_ part: DayPart, _ minute: Int) -> Int {
        abs((part.startMinute + part.endMinute) - 2 * minute)
    }
}

/// How a named-slot dose ("Morning") reads when its clock, the home clock and the device
/// may differ (decided 2026-10-23: "Morning (Paris)", "Home: Night").
///
/// - On one clock (at home): "Morning", nothing else — as before.
/// - Following the device, away from home: "Morning (Paris)" and "Home: Night · 2:00 AM".
/// - Kept on home time, away from home: "Morning (home)" and "Here: Afternoon · 2:00 PM".
/// - On a third clock (a dose planned in another place, seen later): "Morning (Paris)"
///   and the home (or, away from home, the local) clock.
///
/// "Differs" is a different UTC offset at the window's middle, as in `ZonedTimeFormatter`.
/// The part of day on the other clock is read at the window's middle too, so a Paris
/// morning (6–12) is "Night" in New York (0–6). Compiled into the app and the widget.
nonisolated struct SlotClockLabel {
    enum Placement: Equatable {
        /// Home, the dose's clock and the device agree.
        case oneClock
        /// On the device's clock, away from home. The associated value is the place.
        case followsDevice(String)
        /// On the home clock, the device elsewhere.
        case onHome
        /// On a clock that is neither the device's nor home's.
        case elsewhere(String)
    }

    let slotTitle: String
    let clock: TimeZone
    let home: TimeZone
    let device: TimeZone
    let dayParts: DayParts
    let locale: Locale
    let placement: Placement
    /// The window's middle: where placement and the other clock's part of day are read.
    let reference: Date

    init(
        slotTitle: String,
        windowStart: Date,
        windowEnd: Date,
        clock: TimeZone?,
        home: TimeZone?,
        device: TimeZone = .current,
        dayParts: DayParts = .standard,
        locale: Locale = .current
    ) {
        let home = home ?? device
        let clock = clock ?? home
        let reference = windowStart.addingTimeInterval(max(0, windowEnd.timeIntervalSince(windowStart)) / 2)
        self.slotTitle = slotTitle
        self.clock = clock
        self.home = home
        self.device = device
        self.dayParts = dayParts
        self.locale = locale
        self.reference = reference

        let offset = { (zone: TimeZone) in zone.secondsFromGMT(for: reference) }
        let clockIsDevice = offset(clock) == offset(device)
        let clockIsHome = offset(clock) == offset(home)
        switch (clockIsDevice, clockIsHome) {
        case (true, true): placement = .oneClock
        case (true, false): placement = .followsDevice(Self.placeName(of: clock, at: reference))
        case (false, true): placement = .onHome
        case (false, false): placement = .elsewhere(Self.placeName(of: clock, at: reference))
        }
    }

    /// Whether anything beyond the slot's own name needs saying.
    var isOneClock: Bool { placement == .oneClock }

    /// "Morning", "Morning (Paris)", "Morning (home)".
    var title: String { titled(slotTitle) }

    /// `base` with the clock named after it when away: "Morning dose (Paris)".
    func titled(_ base: String) -> String {
        switch placement {
        case .oneClock:
            return base
        case .followsDevice(let place), .elsewhere(let place):
            return String(localized: "\(base) (\(place))", comment: "A dose slot on the named place's clock, e.g. Morning (Paris)")
        case .onHome:
            return String(localized: "\(base) (home)", comment: "A dose slot kept on the home clock, e.g. Morning (home)")
        }
    }

    /// "Morning in Paris", "Morning, home time", "Morning".
    var spokenTitle: String {
        switch placement {
        case .oneClock:
            return slotTitle
        case .followsDevice(let place), .elsewhere(let place):
            return String(localized: "\(slotTitle) in \(place)", comment: "Spoken: a dose slot on the named place's clock, e.g. Morning in Paris")
        case .onHome:
            return String(localized: "\(slotTitle), home time", comment: "Spoken: a dose slot kept on the home clock")
        }
    }

    /// `date` on the dose's own clock ("12:00 PM").
    func time(_ date: Date) -> String {
        Self.time(date, in: clock, locale: locale)
    }

    /// `date` with its date on the dose's own clock ("Oct 23, 2026 at 6:00 AM").
    func dateTime(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: clock)
        style.timeZone = clock
        return date.formatted(style)
    }

    /// The other clock: home for a slot that follows the device, here for one kept home.
    private var other: (isHome: Bool, zone: TimeZone)? {
        switch placement {
        case .oneClock: nil
        case .followsDevice: (true, home)
        case .onHome: (false, device)
        case .elsewhere:
            device.secondsFromGMT(for: reference) == home.secondsFromGMT(for: reference) ? (true, home) : (false, device)
        }
    }

    /// The other clock's zone (home, or here for a slot kept home); nil on one clock.
    var otherZone: TimeZone? { other?.zone }

    /// The part of day on the other clock ("Night"); nil on one clock.
    var otherPartOfDay: String? {
        other.map { dayParts.name(at: reference, in: $0.zone) }
    }

    /// "Home: Night" / "Here: Afternoon", without a time (notifications, history, the
    /// widget's one-line rows). nil on one clock.
    var shortDetail: String? {
        guard let other, let part = otherPartOfDay else { return nil }
        return other.isHome
            ? String(localized: "Home: \(part)", comment: "The home clock's part of day for a dose away from home, e.g. Home: Night")
            : String(localized: "Here: \(part)", comment: "The local clock's part of day for a dose kept on home time, e.g. Here: Afternoon")
    }

    /// Spoken `shortDetail`: "at home it's night" / "here it's afternoon".
    var spokenShortDetail: String? {
        guard let other, let part = otherPartOfDay?.lowercased(with: locale) else { return nil }
        return other.isHome
            ? String(localized: "at home it's \(part)", comment: "Spoken: the home clock's part of day, e.g. at home it's night")
            : String(localized: "here it's \(part)", comment: "Spoken: the local part of day, e.g. here it's afternoon")
    }

    /// "Home: Night · 2:00 AM" / "Here: Afternoon · 2:00 PM" — `date` on the other clock;
    /// with `by`, "Home: Night · by 6:00 AM" (for a deadline). nil on one clock.
    func detail(_ date: Date, by: Bool = false) -> String? {
        guard let other, let part = otherPartOfDay else { return nil }
        let time = Self.otherTime(date, in: other.zone, clock: clock, by: by, locale: locale)
        return other.isHome
            ? String(localized: "Home: \(part) · \(time)", comment: "A dose away from home: the home clock's part of day and time, e.g. Home: Night · 2:00 AM")
            : String(localized: "Here: \(part) · \(time)", comment: "A dose kept on home time: the local part of day and time, e.g. Here: Afternoon · 2:00 PM")
    }

    /// Spoken `detail`: "at home it's night, 2:00 AM" / "here it's afternoon, by 6:00 PM".
    func spokenDetail(_ date: Date, by: Bool = false) -> String? {
        guard let other, let part = otherPartOfDay?.lowercased(with: locale) else { return nil }
        let time = Self.otherTime(date, in: other.zone, clock: clock, by: by, locale: locale, spoken: true)
        return other.isHome
            ? String(localized: "at home it's \(part), \(time)", comment: "Spoken: the home clock's part of day and time, e.g. at home it's night, 2:00 AM")
            : String(localized: "here it's \(part), \(time)", comment: "Spoken: the local part of day and time, e.g. here it's afternoon, 2:00 PM")
    }

    // MARK: - Pieces

    /// "Paris", "New York", "Buenos Aires" from the zone's identifier; the abbreviation
    /// ("GMT+2") for zones without a place ("UTC", "Etc/GMT-2").
    static func placeName(of zone: TimeZone, at date: Date = .now) -> String {
        let parts = zone.identifier.split(separator: "/")
        if parts.count >= 2, parts.first != "Etc", let last = parts.last {
            return last.replacingOccurrences(of: "_", with: " ")
        }
        return zone.abbreviation(for: date) ?? zone.identifier
    }

    /// The other clock's time, with its weekday when that clock is on another date
    /// ("11:00 PM Mon").
    private static func otherTime(_ date: Date, in zone: TimeZone, clock: TimeZone, by: Bool, locale: Locale, spoken: Bool = false) -> String {
        var text = time(date, in: zone, locale: locale)
        var a = Calendar(identifier: .gregorian)
        a.timeZone = zone
        var b = Calendar(identifier: .gregorian)
        b.timeZone = clock
        let x = a.dateComponents([.year, .month, .day], from: date)
        let y = b.dateComponents([.year, .month, .day], from: date)
        if x.year != y.year || x.month != y.month || x.day != y.day {
            var style = Date.FormatStyle(locale: locale, timeZone: zone).weekday(spoken ? .wide : .abbreviated)
            style.timeZone = zone
            text += " " + date.formatted(style)
        }
        return by ? String(localized: "by \(text)", comment: "A deadline, e.g. by 6:00 AM") : text
    }

    private static func time(_ date: Date, in zone: TimeZone, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone)
        style.timeZone = zone
        return date.formatted(style)
    }
}
