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
}

struct DoseCalendarView: UIViewRepresentable {
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

            let color = uiColor(summary.primaryStatus.themeColor).withAlphaComponent(summary.isForecasted ? 0.45 : 1)
            let size: UICalendarView.DecorationSize = summary.count > 2 ? .large : .medium
            return .default(color: color, size: size)
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
