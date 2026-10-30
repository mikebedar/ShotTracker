import Atelier
import Foundation
import SwiftUI
import Testing
@testable import ShotTracker

/// Which calendar days get the hatched dot (`CalendarDaySummary.isMissedOrSkipped`): a past day with a missed dose and a
/// day whose doses were all skipped; never today's overdue dose (it can still be taken) or a forecast. The clock is
/// pinned: `today` is passed in.
@MainActor
struct CalendarDayHatchTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static let today = day(2026, 10, 29)
    private static let yesterday = day(2026, 10, 28)
    private static let tomorrow = day(2026, 10, 30)

    private static func summary(_ date: Date, _ status: DoseStatus, forecasted: Bool = false) -> CalendarDaySummary {
        CalendarDaySummary(date: date, count: 1, primaryStatus: status, isForecasted: forecasted)
    }

    @Test func aPastDayWithAMissedDoseIsHatched() {
        #expect(Self.summary(Self.yesterday, .overdue).isMissedOrSkipped(today: Self.today))
    }

    @Test func todaysOverdueDoseKeepsThePlainDot() {
        #expect(!Self.summary(Self.today, .overdue).isMissedOrSkipped(today: Self.today))
    }

    @Test func aSkippedDayIsHatchedWhenever() {
        #expect(Self.summary(Self.yesterday, .skipped).isMissedOrSkipped(today: Self.today))
        #expect(Self.summary(Self.today, .skipped).isMissedOrSkipped(today: Self.today))
    }

    @Test(arguments: [DoseStatus.upcoming, .due, .takenOnTime, .takenLate, .snoozed])
    func otherStatusesKeepThePlainDot(status: DoseStatus) {
        #expect(!Self.summary(Self.yesterday, status).isMissedOrSkipped(today: Self.today))
        #expect(!Self.summary(Self.today, status).isMissedOrSkipped(today: Self.today))
    }

    @Test func forecastsAreNeverHatched() {
        #expect(!Self.summary(Self.tomorrow, .skipped, forecasted: true).isMissedOrSkipped(today: Self.today))
        #expect(!Self.summary(Self.yesterday, .overdue, forecasted: true).isMissedOrSkipped(today: Self.today))
    }

    /// The hatch is a cue, so its lines keep 3:1 against the dot's ground on ShotTracker's theme, light and dark, at
    /// standard and increased contrast, measured as Atelier's tile backend draws them (under Increase Contrast inks and
    /// ground both step up one role: `PatternInk.raised`). The tone's `subtleFill` ground measured 1:1 there.
    @Test(arguments: [DoseStatus.overdue, .skipped])
    func hatchedDotLinesReadOnTheirGround(status: DoseStatus) throws {
        let theme = ShotTrackerTheme.theme
        let fill = DoseCalendarView.hatchedDotFill(tone: status.tone)
        let ink = try #require(fill.inks.first)
        let ground = try #require(fill.ground)
        for scheme in [ColorScheme.light, .dark] {
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let increased = contrast == .increased
                let base = PatternInk.surface(.base).value(theme: theme, scheme: scheme, contrast: contrast)
                let groundValue = (increased ? ground.raised : ground).value(theme: theme, scheme: scheme, contrast: contrast)
                    .over(base)
                let inkValue = (increased ? ink.raised : ink).value(theme: theme, scheme: scheme, contrast: contrast)
                    .over(groundValue)
                let ratio = ColorValue.contrastRatio(inkValue, groundValue)
                #expect(ratio >= 3, "\(status) \(scheme) \(contrast): \(String(format: "%.2f", ratio)):1")
            }
        }
    }
}
