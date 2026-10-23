import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\ScheduledDose.scheduledAt)]) private var doses: [ScheduledDose]
    @Query(
        filter: #Predicate<Medication> { $0.isActive },
        sort: [SortDescriptor(\Medication.displayName)]
    ) private var medications: [Medication]

    @AppStorage("todayView.mode") private var viewModeRawValue = TodayViewMode.list.rawValue
    @State private var selectedCalendarDate = Calendar.current.startOfDay(for: .now)
    @State private var toastMessage: String?
    @State private var takeConfirmation: TakeConfirmation?

    private struct TakeConfirmation: Identifiable {
        let id = UUID()
        let dose: ScheduledDose
        let message: String
    }

    /// Roughly one `SimpleDoseRow` (~52pt artwork + text) plus the section's vertical
    /// padding — the floor the calendar-mode day list should never shrink below.
    @ScaledMetric(relativeTo: .body) private var minimumDayListHeight: CGFloat = 140

    private var viewMode: TodayViewMode {
        get { TodayViewMode(rawValue: viewModeRawValue) ?? .list }
        nonmutating set { viewModeRawValue = newValue.rawValue }
    }

    /// Every persisted dose of an active medication — resolved ones included, so the
    /// calendar shows what was taken, skipped or missed on past days (and today's taken
    /// doses don't vanish from the selected day's list).
    private var calendarDoses: [ScheduledDose] {
        doses.filter { $0.medication?.isActive != false }
    }

    private var calendar: Calendar {
        Calendar.current
    }

    /// The calendar page bound also set on `DoseCalendarView`'s `availableDateRange` —
    /// forecast generation only needs to cover what the user can actually scroll to.
    private var forecastRange: ClosedRange<Date>? {
        guard
            let start = calendar.date(byAdding: .day, value: DoseRepository.materializationLookaheadDays + 1, to: .now),
            let end = calendar.date(byAdding: .year, value: 2, to: .now),
            start <= end
        else { return nil }
        return start...end
    }

    /// Occurrences beyond the persisted materialization window, computed live — see
    /// `DoseForecastService`. Never persisted; read-only, dimmed in the UI.
    private var forecastItems: [DisplayDoseItem] {
        guard let forecastRange else { return [] }
        return DoseForecastService.occurrences(
            for: medications,
            engine: dependencies.scheduleEngine,
            in: forecastRange,
            preferences: dependencies.preferencesStore.preferences
        )
    }

    /// Persisted + forecasted doses combined, for calendar display only.
    private var calendarDisplayItems: [DisplayDoseItem] {
        let persisted = calendarDoses.map { dose in
            DisplayDoseItem(dose: dose, status: dependencies.statusEvaluator.effectiveStatus(for: dose))
        }
        return persisted + forecastItems
    }

    private var selectedDayDoses: [DisplayDoseItem] {
        let dayStart = calendar.startOfDay(for: selectedCalendarDate)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        return calendarDisplayItems
            .filter { $0.dose.scheduledAt >= dayStart && $0.dose.scheduledAt < nextDay }
            .sorted { $0.dose.scheduledAt < $1.dose.scheduledAt }
    }

    private var calendarSummaries: [CalendarDaySummary] {
        Dictionary(grouping: calendarDisplayItems, by: { calendar.startOfDay(for: $0.dose.scheduledAt) })
            .map { day, items in
                CalendarDaySummary(
                    date: day,
                    count: items.count,
                    primaryStatus: items.map(\.status).min(by: { $0.priority < $1.priority }) ?? .upcoming,
                    isForecasted: items.allSatisfy(\.isForecasted)
                )
            }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            // Re-render every minute so a dose flips upcoming → due → overdue on screen
            // as its window opens and closes, not only when something else changes.
            TimelineView(.everyMinute) { _ in
                if viewMode == .list {
                    listModeContent
                } else {
                    calendarModeContent
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(viewMode == .list ? .large : .inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View Mode", selection: Binding(
                        get: { viewMode },
                        set: { viewMode = $0 }
                    )) {
                        ForEach(TodayViewMode.allCases) { mode in
                            Image(systemName: mode.symbolName)
                                .accessibilityLabel(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .accessibilityIdentifier(AccessibilityID.todayViewModeSwitcher)
                }
            }
            .alert(
                "Take dose early?",
                isPresented: Binding(
                    get: { takeConfirmation != nil },
                    set: { if !$0 { takeConfirmation = nil } }
                ),
                presenting: takeConfirmation
            ) { confirmation in
                Button("Take Anyway") { performTake(confirmation.dose) }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
        }
    }

    private var navigationTitle: String {
        switch viewMode {
        case .list: "Today"
        case .calendar: selectedCalendarDate.formatted(.dateTime.month(.wide).year())
        }
    }

    private var listModeContent: some View {
        let buckets = TodayBucketing.bucket(
            doses: doses,
            statusFor: { dependencies.statusEvaluator.effectiveStatus(for: $0) }
        )
        let comingUpGroups = TodayBucketing.longRangeComingUp(
            medications: medications,
            statusFor: { dependencies.statusEvaluator.effectiveStatus(for: $0) },
            engine: dependencies.scheduleEngine,
            preferences: dependencies.preferencesStore.preferences,
            forecastLimit: forecastRange?.upperBound ?? calendar.date(byAdding: .year, value: 2, to: .now) ?? .now
        )

        let pendingEmpty = pendingBucketsEmpty(buckets)
        let hasAnything = !allBucketsEmpty(buckets) || !comingUpGroups.isEmpty

        return ScrollView {
            if !hasAnything {
                ContentUnavailableView(
                    "Nothing due right now",
                    systemImage: "checkmark.circle",
                    description: Text("Add a medication to start tracking doses and reminders.")
                )
                .padding(.top, Theme.Spacing.s7)
            } else {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.s6) {
                    if pendingEmpty {
                        if buckets.completed.isEmpty {
                            EmptyStateBanner(
                                title: "Nothing scheduled today",
                                systemImage: "sparkles",
                                subtitle: "Enjoy your day — upcoming doses are below.",
                                tint: Theme.Color.accent
                            )
                        } else {
                            EmptyStateBanner(
                                title: "You're all caught up",
                                systemImage: "checkmark.circle.fill",
                                subtitle: "Every dose scheduled for today is handled."
                            )
                        }
                    }
                    bucketSection(title: "Overdue", doses: buckets.overdue, tone: .attention)
                    bucketSection(title: "Take Now", doses: buckets.takeNow)
                    bucketSection(title: "Coming Up Soon", doses: buckets.comingUpSoon)
                    bucketSection(title: "Later Today", doses: buckets.laterToday)
                    bucketSection(title: "Tonight", doses: buckets.tonight)
                    bucketSection(title: "Completed", doses: buckets.completed)
                    comingUpSection(groups: comingUpGroups)
                }
                .padding(Theme.Spacing.s4)
            }
        }
        .background(Theme.Color.background)
        .accessibilityElement(children: .contain)
        .refreshable {
            dependencies.refreshSchedules(context: modelContext)
        }
        .toast($toastMessage)
    }

    /// True when nothing needs action today (ignores the Completed bucket).
    private func pendingBucketsEmpty(_ buckets: TodayBuckets) -> Bool {
        buckets.overdue.isEmpty && buckets.takeNow.isEmpty && buckets.comingUpSoon.isEmpty
            && buckets.laterToday.isEmpty && buckets.tonight.isEmpty
    }

    private func allBucketsEmpty(_ buckets: TodayBuckets) -> Bool {
        pendingBucketsEmpty(buckets) && buckets.completed.isEmpty
    }

    @ViewBuilder
    private func bucketSection(title: String, doses: [ScheduledDose], tone: SectionHeader.Tone = .regular) -> some View {
        if !doses.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
                SectionHeader(title: title, count: doses.count, tone: tone)
                ForEach(doses) { dose in
                    let status = dependencies.statusEvaluator.effectiveStatus(for: dose)
                    DoseCard(
                        dose: dose,
                        status: status,
                        onTake: { takeDose(dose) },
                        onSnooze: DoseActions.canSnooze(dose, status: status) ? { snoozeDose(dose) } : nil,
                        onSkip: { skipDose(dose) },
                        onUndo: { undoDose(dose) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func comingUpSection(groups: [TodayBucketing.ComingUpGroup]) -> some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
                SectionHeader(title: "Coming Up")
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        DateGroupLabel(text: group.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        ForEach(group.items) { item in
                            ComingUpRow(dose: item.dose, medication: item.medication, isForecasted: item.isForecasted)
                        }
                    }
                }
            }
        }
    }

    private var calendarModeContent: some View {
        VStack(spacing: 0) {
            // No fixed height here: DoseCalendarView reports its real fitting size (via
            // sizeThatFits) so the full month is always visible — a 6-week month needs
            // more room than a 4-week one, and a fixed height would crop or waste space.
            DoseCalendarView(
                summaries: calendarSummaries,
                selectedDate: $selectedCalendarDate
            )
            .padding(.horizontal)
            .accessibilityIdentifier(AccessibilityID.todayCalendarView)
            .layoutPriority(1)

            Divider()

            // This list absorbs whatever space the calendar didn't need, but never
            // shrinks below one row + padding so it can't disappear entirely.
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
                    Text(selectedCalendarDate.formatted(date: .complete, time: .omitted))
                        .font(Theme.Font.display(.headline))

                    if selectedDayDoses.isEmpty {
                        Text("No scheduled doses for this day.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedDayDoses) { item in
                            SimpleDoseRow(
                                dose: item.dose,
                                medication: item.medication,
                                status: item.status,
                                isForecasted: item.isForecasted
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.s4)
            }
            .frame(maxHeight: .infinity)
            .frame(minHeight: minimumDayListHeight)
        }
        .background(Theme.Color.background)
    }

    private func takeDose(_ dose: ScheduledDose) {
        if let medication = dose.medication,
           let regimen = medication.regimens.active,
           let warning = DoseRescheduling.minimumIntervalWarning(for: medication, regimen: regimen) {
            takeConfirmation = TakeConfirmation(dose: dose, message: warning.message)
        } else {
            performTake(dose)
        }
    }

    private func performTake(_ dose: ScheduledDose) {
        dependencies.recordDoseAction(.taken, dose: dose, context: modelContext)
        toastMessage = "Marked \(dose.medication?.displayName ?? "dose") as taken"
    }

    private func snoozeDose(_ dose: ScheduledDose) {
        dependencies.recordDoseAction(.snoozed, dose: dose, context: modelContext)
        toastMessage = "Snoozed \(dose.medication?.displayName ?? "dose")"
    }

    private func skipDose(_ dose: ScheduledDose) {
        dependencies.recordDoseAction(.skipped, dose: dose, context: modelContext)
        toastMessage = "Skipped \(dose.medication?.displayName ?? "dose")"
    }

    private func undoDose(_ dose: ScheduledDose) {
        dependencies.recordDoseAction(.pending, dose: dose, context: modelContext)
        toastMessage = "Undid \(dose.medication?.displayName ?? "dose")"
    }
}

private enum TodayViewMode: String, CaseIterable, Identifiable {
    case list
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "List"
        case .calendar: "Calendar"
        }
    }

    var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .calendar: "calendar"
        }
    }
}

private extension DoseStatus {
    var priority: Int {
        switch self {
        case .overdue: 0
        case .due: 1
        case .snoozed: 2
        case .upcoming: 3
        case .takenLate: 4
        case .takenOnTime: 5
        case .skipped: 6
        }
    }
}
