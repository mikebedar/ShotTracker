import Foundation

/// How a dose time reads when its schedule lives in a different time zone than the
/// device. Schedules keep their **home** zone (the one they were created in); a dose
/// fires at the true instant wherever the user is. When the device is somewhere else,
/// every dose time shows both clocks — "8:00 AM home · 2:00 PM here" — and nothing
/// changes when the two agree.
///
/// "Differs" means a different UTC offset *at that instant*, not a different zone
/// identifier: Detroit and New York never show two identical times, and New York vs
/// Paris shows both even in the March and October weeks when their offsets are five
/// hours apart instead of six.
///
/// Compiled into the app and the widget (no SwiftData, no app models).
nonisolated struct ZonedTimeFormatter {
    let home: TimeZone
    let local: TimeZone
    let locale: Locale
    /// What the local side is called when it isn't the device's clock: history reads a
    /// dose on the clock it was taken on, "2:05 AM home · 8:05 AM Paris". nil = "here".
    let localName: String?

    /// `home` nil (a dose with no regimen to ask) reads as local — one time, as before.
    init(home: TimeZone?, local: TimeZone = .current, locale: Locale = .current, localName: String? = nil) {
        self.home = home ?? local
        self.local = local
        self.locale = locale
        self.localName = localName
    }

    /// Whether `date` reads differently on the home and the local clock.
    func differs(at date: Date) -> Bool {
        home.secondsFromGMT(for: date) != local.secondsFromGMT(for: date)
    }

    /// "8:00 AM", or "8:00 AM home · 2:00 PM here". The home part names its weekday when
    /// it falls on another day than the local one ("11:00 PM Mon home · 5:00 AM here") —
    /// lists group by the local day, so the local time never needs one.
    func time(_ date: Date) -> String {
        let localText = Self.time(date, in: local, locale: locale)
        guard differs(at: date) else { return localText }
        var homeText = Self.time(date, in: home, locale: locale)
        if !sameDay(date) {
            homeText += " " + Self.weekday(date, in: home, locale: locale)
        }
        if let localName {
            return String(
                localized: "\(homeText) home · \(localText) \(localName)",
                comment: "A dose time on the home clock and on the clock of the place it was logged in, e.g. 2:05 AM home · 8:05 AM Paris"
            )
        }
        return String(
            localized: "\(homeText) home · \(localText) here",
            comment: "A dose time on the medication's home clock and on the device's clock, e.g. 8:00 AM home · 2:00 PM here"
        )
    }

    /// "Oct 23, 2026 at 8:00 AM" (as before), or, shorter since it carries two clocks,
    /// "Oct 23 at 8:00 AM home · 2:00 PM here" (the local part gets its own date only when
    /// the day differs: "Oct 23 at 11:00 PM home · Oct 24 at 5:00 AM here").
    func dateTime(_ date: Date) -> String {
        guard differs(at: date) else { return Self.dateTime(date, in: local, locale: locale) }
        let homeText = Self.shortDateTime(date, in: home, locale: locale)
        let hereText = sameDay(date)
            ? Self.time(date, in: local, locale: locale)
            : Self.shortDateTime(date, in: local, locale: locale)
        if let localName {
            return String(
                localized: "\(homeText) home · \(hereText) \(localName)",
                comment: "A dose date and time on the home clock and on the clock of the place it was logged in"
            )
        }
        return String(
            localized: "\(homeText) home · \(hereText) here",
            comment: "A dose date and time on the medication's home clock and on the device's clock"
        )
    }

    /// What VoiceOver says: "8:00 AM", or "8:00 AM home time, 2:00 PM local time" — the
    /// "·" and "here" shorthand reads poorly aloud.
    func spokenTime(_ date: Date) -> String {
        let localText = Self.time(date, in: local, locale: locale)
        guard differs(at: date) else { return localText }
        var homeText = Self.time(date, in: home, locale: locale)
        if !sameDay(date) {
            homeText += " " + Self.weekday(date, in: home, locale: locale, width: .wide)
        }
        if let localName {
            return String(
                localized: "\(homeText) home time, \(localText) \(localName) time",
                comment: "Spoken dose time on the home clock and on the clock of the place it was logged in"
            )
        }
        return String(
            localized: "\(homeText) home time, \(localText) local time",
            comment: "Spoken dose time on the home and the local clock"
        )
    }

    /// For exports, where "home" and "here" lose their meaning: "8:00 AM" when the clocks
    /// agree, else "8:00 AM EDT (2:00 PM GMT+2 local)".
    func timeWithZoneNames(_ date: Date) -> String {
        guard differs(at: date) else { return Self.time(date, in: local, locale: locale) }
        let homeText = Self.time(date, in: home, locale: locale) + " " + Self.abbreviation(of: home, at: date)
        let localText = Self.time(date, in: local, locale: locale) + " " + Self.abbreviation(of: local, at: date)
        return String(
            localized: "\(homeText) (\(localText) local)",
            comment: "Exported dose time with zone abbreviations, home first, e.g. 8:00 AM EDT (2:00 PM GMT+2 local)"
        )
    }

    // MARK: - Zone names

    /// "New York (Eastern Time)", "Paris (Central European Time)", "UTC".
    static func displayName(of zone: TimeZone, locale: Locale = .current) -> String {
        let generic = zone.localizedName(for: .generic, locale: locale)
        guard zone.identifier.contains("/") else { return generic ?? zone.identifier }
        let city = zone.identifier
            .split(separator: "/").last.map(String.init)?
            .replacingOccurrences(of: "_", with: " ") ?? zone.identifier
        guard let generic, generic != city else { return city }
        return "\(city) (\(generic))"
    }

    /// "EDT", "GMT+2" — what the system calls the zone at that instant.
    static func abbreviation(of zone: TimeZone, at date: Date) -> String {
        zone.abbreviation(for: date) ?? zone.identifier
    }

    // MARK: - Pieces

    private func sameDay(_ date: Date) -> Bool {
        var homeCalendar = Calendar(identifier: .gregorian)
        homeCalendar.timeZone = home
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = local
        let a = homeCalendar.dateComponents([.year, .month, .day], from: date)
        let b = localCalendar.dateComponents([.year, .month, .day], from: date)
        return a.year == b.year && a.month == b.month && a.day == b.day
    }

    private static func time(_ date: Date, in zone: TimeZone, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone)
        style.timeZone = zone
        return date.formatted(style)
    }

    private static func dateTime(_ date: Date, in zone: TimeZone, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: zone)
        style.timeZone = zone
        return date.formatted(style)
    }

    /// "Oct 23 at 8:00 AM" — month, day and time, no year.
    private static func shortDateTime(_ date: Date, in zone: TimeZone, locale: Locale) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: zone).month(.abbreviated).day().hour().minute()
        style.timeZone = zone
        return date.formatted(style)
    }

    private static func weekday(
        _ date: Date,
        in zone: TimeZone,
        locale: Locale,
        width: Date.FormatStyle.Symbol.Weekday = .abbreviated
    ) -> String {
        var style = Date.FormatStyle(locale: locale, timeZone: zone).weekday(width)
        style.timeZone = zone
        return date.formatted(style)
    }
}
