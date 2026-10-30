import Atelier
import SwiftUI
import UIKit

struct CalendarDaySummary: Hashable, Identifiable {
    let date: Date
    let count: Int
    let primaryStatus: DoseStatus
    /// True when every dose on this day is a forecasted (not-yet-materialized) projection
    /// rather than a persisted, actionable `ScheduledDose` — rendered with a dimmed dot.
    var isForecasted: Bool = false

    var id: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    /// Whether the day's dot is hatched: every dose that day was skipped, or a dose was missed (still overdue once
    /// the day is over; `today` is the start of today). Today's overdue dose can still be taken, so it keeps the
    /// plain dot. The hatch is the cue that doesn't rely on colour (a red or grey dot was the only difference); the
    /// day's list below the calendar says which.
    func isMissedOrSkipped(today: Date) -> Bool {
        guard !isForecasted else { return false }
        return primaryStatus == .skipped || (primaryStatus == .overdue && date < today)
    }
}

struct DoseCalendarView: UIViewRepresentable {
    /// A missed or skipped day's dot: Atelier's hatch in the status tone's content colour over a quiet tint of the
    /// tone. Not over the tone's `subtleFill`: under Increase Contrast a pattern's ground steps up one role as well
    /// (`subtleFill` → `border`, the tone at full strength), and the lines measured 1:1 against it and vanished.
    /// `CalendarDayHatchTests` holds the lines to 3:1 on their ground in both schemes and contrasts.
    nonisolated static func hatchedDotFill(tone: Tone) -> PatternFill {
        PatternFill.hatch(.degrees(45), spacing: .points(3)) // ds-allow: a hatch that reads in an 11-point dot
            .ink(.tone(tone, .content))
            .ground(.quiet(.tone(tone, .fill)))
    }

    let summaries: [CalendarDaySummary]
    @Binding var selectedDate: Date

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UICalendarView {
        let calendarView = UICalendarView()
        calendarView.delegate = context.coordinator
        calendarView.calendar = Calendar.current
        calendarView.locale = Locale.current
        context.coordinator.environment = context.environment
        calendarView.tintColor = context.coordinator.uiColor(Theme.Color.accent)
        calendarView.backgroundColor = .clear
        calendarView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        calendarView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        // Bound how far the calendar can page. Beyond the persisted materialization
        // window, dates are served live via DoseForecastService (see TodayView), but
        // that lens still needs an edge somewhere — without a bound, paging forward
        // would eventually run past even the forecast range into an unbounded, silent
        // void. UIKit visually stops paging at this edge, a familiar affordance (the
        // same way a date picker caps how far ahead you can pick a date).
        let today = Calendar.current.startOfDay(for: .now)
        if
            let past = Calendar.current.date(byAdding: .year, value: -2, to: today),
            let future = Calendar.current.date(byAdding: .year, value: 2, to: today)
        {
            calendarView.availableDateRange = DateInterval(start: past, end: future)
        }

        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        calendarView.selectionBehavior = selection
        selection.setSelected(context.coordinator.dateComponents(for: selectedDate), animated: false)
        calendarView.visibleDateComponents = context.coordinator.monthComponents(for: selectedDate)
        context.coordinator.lastSelectedMonth = calendarView.visibleDateComponents
        context.coordinator.calendarView = calendarView
        context.coordinator.update(parent: self)

        return calendarView
    }

    func updateUIView(_ uiView: UICalendarView, context: Context) {
        // Days that just lost their last dose (an archived medication) need a reload too,
        // or their old dot stays drawn.
        let previousDays = context.coordinator.summaryDateComponents
        context.coordinator.update(parent: self)
        // The theme (Settings → Appearance) may have changed.
        context.coordinator.environment = context.environment
        context.coordinator.hatchedDots.removeAll()
        uiView.tintColor = context.coordinator.uiColor(Theme.Color.accent)

        if let selection = uiView.selectionBehavior as? UICalendarSelectionSingleDate {
            let components = context.coordinator.dateComponents(for: selectedDate)
            if selection.selectedDate != components {
                selection.setSelected(components, animated: true)
            }
        }

        // Only page when the *selection* moved to another month. Re-setting it on every
        // update snapped the calendar back whenever anything re-rendered while the user
        // was browsing another month.
        let selectedMonth = context.coordinator.monthComponents(for: selectedDate)
        if context.coordinator.lastSelectedMonth != selectedMonth {
            context.coordinator.lastSelectedMonth = selectedMonth
            uiView.visibleDateComponents = selectedMonth
        }

        var reload = context.coordinator.summaryDateComponents
        let current = Set(reload.map { [$0.year, $0.month, $0.day] })
        reload += previousDays.filter { !current.contains([$0.year, $0.month, $0.day]) }
        uiView.reloadDecorations(forDateComponents: reload, animated: true)
    }

    /// Report UICalendarView's real fitting height for the given width, instead of
    /// letting SwiftUI guess — a month with 6 weeks needs more vertical space than one
    /// with 4, and without this the calendar either crops a row or leaves dead space.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        let targetWidth = proposal.width ?? uiView.intrinsicContentSize.width
        let fitting = uiView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: targetWidth, height: fitting.height)
    }

    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var parent: DoseCalendarView
        weak var calendarView: UICalendarView?
        var lastSelectedMonth: DateComponents?
        /// The SwiftUI environment the theme's colours resolve in.
        var environment = EnvironmentValues()
        private var summaryByKey: [String: CalendarDaySummary] = [:]

        init(parent: DoseCalendarView) {
            self.parent = parent
        }

        func update(parent: DoseCalendarView) {
            self.parent = parent
            summaryByKey = Dictionary(uniqueKeysWithValues: parent.summaries.map { (key(for: $0.date), $0) })
        }

        var summaryDateComponents: [DateComponents] {
            parent.summaries.map { dateComponents(for: $0.date) }
        }

        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            guard let date = calendarView.calendar.date(from: dateComponents) else { return nil }
            guard let summary = summaryByKey[key(for: date)] else { return nil }

            let size: UICalendarView.DecorationSize = summary.count > 2 ? .large : .medium
            if summary.isMissedOrSkipped(today: Calendar.current.startOfDay(for: .now)),
               let dot = hatchedDot(tone: summary.primaryStatus.tone, large: size == .large) {
                // A custom view at the image's intrinsic size (UIKit centres it like the default dot):
                // `.image(_:size:)` stretched it into a wide capsule.
                return .customView { UIImageView(image: dot) }
            }
            let color = uiColor(summary.primaryStatus.themeColor).withAlphaComponent(summary.isForecasted ? 0.45 : 1)
            return .default(color: color, size: size)
        }

        /// Hatched dots by tone and size (light and dark in one `UIImageAsset`, so the image view follows the
        /// scheme). Emptied on every update: the theme or the contrast may have changed.
        var hatchedDots: [HatchedDotKey: UIImage] = [:]

        struct HatchedDotKey: Hashable {
            let tone: Tone
            let large: Bool
        }

        /// A dot about the size of UIKit's default decoration, filled with `DoseCalendarView.hatchedDotFill(tone:)`,
        /// drawn once per scheme with `ImageRenderer`.
        func hatchedDot(tone: Tone, large: Bool) -> UIImage? {
            let key = HatchedDotKey(tone: tone, large: large)
            if let cached = hatchedDots[key] { return cached }
            let diameter = Self.hatchedDotDiameter(large: large)
            let fill = DoseCalendarView.hatchedDotFill(tone: tone)
            let scale = calendarView?.traitCollection.displayScale ?? environment.displayScale
            // Each variant is registered with the display scale too: with the interface style alone the asset handed
            // back a 1× image of the 3× pixels, three times too big.
            func traits(_ style: UIUserInterfaceStyle) -> UITraitCollection {
                UITraitCollection { $0.userInterfaceStyle = style; $0.displayScale = scale }
            }
            let asset = UIImageAsset()
            for style in [UIUserInterfaceStyle.light, .dark] {
                var resolved = environment
                resolved.colorScheme = style == .dark ? .dark : .light
                resolved.displayScale = scale
                let renderer = ImageRenderer(content: Circle().fill(fill)
                    .frame(width: diameter, height: diameter)
                    .environment(\.self, resolved))
                renderer.scale = scale
                guard let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal) else { return nil }
                asset.register(image, with: traits(style))
            }
            let style: UIUserInterfaceStyle = calendarView?.traitCollection.userInterfaceStyle == .dark ? .dark : .light
            let dot = asset.image(with: traits(style))
            hatchedDots[key] = dot
            return dot
        }

        /// The default medium dot measured 32 px at 3× on iOS 27 (about 11 pt); large is about a third bigger.
        static func hatchedDotDiameter(large: Bool) -> CGFloat {
            large ? 14 : 11 // ds-allow: UICalendarView's decoration dot sizes
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard
                let dateComponents,
                let date = calendarView?.calendar.date(from: dateComponents)
            else {
                return
            }

            let normalized = Calendar.current.startOfDay(for: date)
            if parent.selectedDate != normalized {
                parent.selectedDate = normalized
            }
        }

        func dateComponents(for date: Date) -> DateComponents {
            Calendar.current.dateComponents([.calendar, .era, .year, .month, .day], from: date)
        }

        func monthComponents(for date: Date) -> DateComponents {
            Calendar.current.dateComponents([.calendar, .year, .month], from: date)
        }

        /// A theme colour as a dynamic `UIColor`: resolved for light or dark as UIKit asks.
        func uiColor(_ style: ThemeColor) -> UIColor {
            let environment = environment
            return UIColor { traits in
                var resolved = environment
                resolved.colorScheme = traits.userInterfaceStyle == .dark ? .dark : .light
                return UIColor(style.resolve(in: resolved))
            }
        }

        private func key(for date: Date) -> String {
            let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
        }
    }
}
