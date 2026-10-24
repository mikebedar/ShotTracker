import PhotosUI
import SwiftData
import SwiftUI

struct MedicationDraft {
    var displayName = ""
    var canonicalName = ""
    var normalizedMedicationCode = ""
    var notes = ""
    var imageData: Data?
    var kind: MedicationKind = .oral
    var takeWithFood = false
    var timeSensitiveOverride: Bool? = nil
    var selectedStrengthAndForm: String?
    var drugLabelInfo: DrugLabelInfo?
    var tracksSupply = false
    var supplyUnitLabel = ""
    var unitsPerContainer = 30
    var onHandUnits = 30
    var supplyLowThreshold = 6
    var anchorDate = Date()
    /// The clock the schedule's times are on — the device's for a new medication, the
    /// regimen's own when editing (an edit made while travelling used to re-home the
    /// schedule to wherever the phone was). Changing it creates a new regimen version.
    var homeTimeZoneIdentifier = TimeZone.current.identifier
    /// The travel clock ("When you travel → Clock"): nil = by timing kind (named slots follow the device, specific
    /// times stay home). Changing what it means for any timing is a schedule change.
    var travelPolicy: TravelTimePolicy?
    /// "Long trips & date lines" (calendar day / at least N hours).
    var travelSpacing: TravelSpacing = .calendarDay
    /// The N of hours mode. Follows the frequency (`TravelSettings.defaultMinimumHours`)
    /// until the user changes it (`travelMinimumHoursSet`).
    var travelMinimumHours = 20
    var travelMinimumHoursSet = false
    /// "Landing during a dose".
    var travelLanding: TravelLanding = .finishOnOldClock
    var frequency: ScheduleFrequency = .daily
    var intervalDays = 1
    /// Defaults to today's weekday / day of month, not a fixed Monday / the 1st.
    var weekdays = Set<Int>([Calendar.current.component(.weekday, from: .now)])
    var dayOfMonth = Calendar.current.component(.day, from: .now)
    var cycleOnDays = 1
    var cycleOffDays = 0
    var timings: [DailyTiming] = [DailyTiming(kind: .morning)]
    var phases: [PhaseDraft] = []
    var graceWindowMinutes = 180
    var missedDosePolicy: MissedDosePolicy = .keepToSchedule
    var minimumIntervalDays = 3
    var remindersEnabled = true
    var dueRemindersEnabled = true
    var overdueRemindersEnabled = true
    var playSound = true
    var allowSnooze = true
    var defaultSnoozeMinutes = 20
    var maxReminderCount = 6
    var escalationIntervalsText = "0,30,120,720,1440"
    var routineWindowMinutes = 90

    init() {}

    init(medication: Medication) {
        displayName = medication.displayName
        canonicalName = medication.canonicalName ?? ""
        normalizedMedicationCode = medication.normalizedMedicationCode ?? ""
        notes = medication.notes
        imageData = medication.imageData
        kind = medication.kind
        takeWithFood = medication.takeWithFood
        timeSensitiveOverride = medication.timeSensitiveNotifications
        selectedStrengthAndForm = medication.selectedStrengthAndForm
        drugLabelInfo = medication.drugLabelInfo
        tracksSupply = medication.isTrackingSupply
        supplyUnitLabel = medication.supplyUnitLabel ?? ""
        unitsPerContainer = medication.unitsPerContainer ?? 30
        onHandUnits = medication.isTrackingSupply ? medication.totalRemaining : 30
        supplyLowThreshold = medication.supplyLowThreshold ?? 6

        if let regimen = medication.regimens.active {
            anchorDate = regimen.anchorDate
            homeTimeZoneIdentifier = regimen.timeZoneIdentifier
            travelPolicy = regimen.travelPolicy
            travelSpacing = regimen.travelSpacing
            travelMinimumHours = regimen.effectiveTravelMinimumHours
            travelMinimumHoursSet = regimen.travelMinimumHours != nil
            travelLanding = regimen.travelLanding
            frequency = regimen.recurrenceRule.frequency
            intervalDays = regimen.recurrenceRule.intervalDays
            weekdays = Set(regimen.recurrenceRule.weekdays)
            dayOfMonth = regimen.recurrenceRule.dayOfMonth
            cycleOnDays = regimen.recurrenceRule.cycleOnDays
            cycleOffDays = regimen.recurrenceRule.cycleOffDays
            timings = regimen.timings.isEmpty ? [DailyTiming(kind: .morning)] : regimen.timings
            phases = regimen.phases
                .sorted { $0.startDayOffset < $1.startDayOffset }
                .map { PhaseDraft(phase: $0) }
            graceWindowMinutes = regimen.graceWindowMinutes
            missedDosePolicy = regimen.missedDosePolicy
            minimumIntervalDays = max(1, Int((Double(regimen.effectiveMinimumIntervalHours) / 24).rounded()))
        }

        if let policy = medication.regimens.active?.activeReminderPolicy {
            remindersEnabled = policy.isEnabled
            dueRemindersEnabled = policy.dueRemindersEnabled
            overdueRemindersEnabled = policy.overdueRemindersEnabled
            playSound = policy.playSound
            allowSnooze = policy.allowSnooze
            defaultSnoozeMinutes = policy.defaultSnoozeMinutes
            maxReminderCount = policy.maxReminderCount
            escalationIntervalsText = policy.escalationIntervalsMinutes.map(String.init).joined(separator: ",")
            routineWindowMinutes = policy.routineSlotReminderWindowMinutes
        }
    }

    var recurrenceRule: RecurrenceRule {
        RecurrenceRule(
            frequency: frequency,
            intervalDays: intervalDays,
            weekdays: Array(weekdays).sorted(),
            dayOfMonth: dayOfMonth,
            cycleOnDays: cycleOnDays,
            cycleOffDays: cycleOffDays
        )
    }

    /// The phase models for a `.phased` regimen: consecutive, starting at day 0. Phase
    /// timings stay empty so every phase uses the regimen's own "When" list.
    func makePhases() -> [RegimenPhase] {
        guard frequency == .phased else { return [] }
        var offset = 0
        return phases.enumerated().map { index, draft in
            let isLast = index == phases.count - 1
            let duration: Int? = isLast && draft.isOngoing ? nil : max(1, draft.durationDays)
            let phase = RegimenPhase(
                title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Phase \(index + 1)" : draft.title,
                startDayOffset: offset,
                durationDays: duration,
                recurrenceRule: RecurrenceRule(frequency: draft.frequency, intervalDays: draft.intervalDays),
                timings: []
            )
            offset += duration ?? 0
            return phase
        }
    }

    /// Whether the schedule differs from `regimen` — only then does a save create a new
    /// regimen version. Every version bump re-keys every future dose, so renaming a
    /// medication or changing its notes used to churn the whole schedule.
    func scheduleDiffers(from regimen: MedicationRegimen?) -> Bool {
        guard let regimen else { return true }
        let calendar = Calendar.current
        let existingPhases = regimen.phases
            .sorted { $0.startDayOffset < $1.startDayOffset }
            .map { PhaseDraft(phase: $0) }
        return !calendar.isDate(anchorDate, inSameDayAs: regimen.anchorDate)
            || homeTimeZoneIdentifier != regimen.timeZoneIdentifier
            || effectiveTravelPolicies != timings.map { TravelTimePolicy.effective(regimen.travelPolicy, for: $0) }
            || travelSpacing != regimen.travelSpacing
            || (travelSpacing == .minimumHours && effectiveTravelMinimumHours != regimen.effectiveTravelMinimumHours)
            || travelLanding != regimen.travelLanding
            || recurrenceRule != regimen.recurrenceRule
            || timings != regimen.timings
            || graceWindowMinutes != regimen.graceWindowMinutes
            || missedDosePolicy != regimen.missedDosePolicy
            || minimumIntervalHours != regimen.minimumIntervalHours
            || (frequency == .phased && phases.map(\.comparable) != existingPhases.map(\.comparable))
    }

    var minimumIntervalHours: Int? {
        missedDosePolicy == .rescheduleFromLastDose ? minimumIntervalDays * 24 : nil
    }

    /// The N hours mode uses: the user's, else the frequency's default.
    var effectiveTravelMinimumHours: Int {
        travelMinimumHoursSet ? travelMinimumHours : TravelSettings.defaultMinimumHours(for: recurrenceRule)
    }

    /// The three travel choices as values (the example and the summary read these).
    var travelSettings: TravelSettings {
        TravelSettings(clock: travelPolicy, spacing: travelSpacing, minimumHours: effectiveTravelMinimumHours, landing: travelLanding)
    }

    /// A new medication's travel choices follow its kind and timings until the user picks
    /// one (`TravelSettings.suggested`).
    mutating func applySuggestedTravelSettings() {
        let suggested = TravelSettings.suggested(kind: kind, timeSensitive: timeSensitiveOverride, timings: timings, rule: recurrenceRule)
        travelPolicy = suggested.clock
        travelSpacing = suggested.spacing
        travelLanding = suggested.landing
    }

    /// The schedule as the travel example simulates it.
    var exampleSchedule: TravelExample.Schedule {
        TravelExample.Schedule(
            timings: timings,
            rule: recurrenceRule,
            anchorDate: anchorDate,
            graceWindowMinutes: graceWindowMinutes,
            missedDosePolicy: missedDosePolicy,
            home: TimeZone(identifier: homeTimeZoneIdentifier) ?? .current,
            travel: travelSettings
        )
    }

    /// The schedule as "How this schedule works" describes it.
    var summaryInputs: ScheduleSummary.Inputs {
        let steps = ScheduleSummary.phaseSteps(phases.enumerated().map { index, phase in
            let isLast = index == phases.count - 1
            let days: Int? = isLast && phase.isOngoing ? nil : max(1, phase.durationDays)
            let title = phase.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Phase \(index + 1)" : phase.title
            return (title, RecurrenceRule(frequency: phase.frequency, intervalDays: phase.intervalDays), days)
        })
        let reminders = reminderPolicy
        return ScheduleSummary.Inputs(
            timings: timings,
            rule: recurrenceRule,
            phaseSteps: frequency == .phased ? steps : [],
            graceWindowMinutes: graceWindowMinutes,
            missedDosePolicy: missedDosePolicy,
            minimumIntervalHours: minimumIntervalDays * 24,
            home: TimeZone(identifier: homeTimeZoneIdentifier) ?? .current,
            travel: travelSettings,
            remindersEnabled: reminders.isEnabled,
            dueRemindersEnabled: reminders.dueRemindersEnabled,
            overdueRemindersEnabled: reminders.overdueRemindersEnabled,
            escalationIntervalsMinutes: reminders.escalationIntervalsMinutes,
            maxReminderCount: reminders.maxReminderCount,
            allowSnooze: reminders.allowSnooze,
            snoozeMinutes: reminders.defaultSnoozeMinutes
        )
    }

    /// What the travel clock means for each timing. Picking the default explicitly
    /// changes nothing, so it doesn't create a new version.
    var effectiveTravelPolicies: [TravelTimePolicy] {
        timings.map { TravelTimePolicy.effective(travelPolicy, for: $0) }
    }

    /// The by-kind default, when every timing has the same one; nil for a mix of named
    /// slots and specific times (then "Automatic" is the default).
    var defaultTravelPolicy: TravelTimePolicy? {
        let defaults = Set(timings.map { TravelTimePolicy.defaultFor(kind: $0.kind) })
        return defaults.count == 1 ? defaults.first : nil
    }

    func reminderPolicyDiffers(from policy: ReminderPolicy?) -> Bool {
        guard let policy else { return true }
        return policy.isEnabled != remindersEnabled
            || policy.dueRemindersEnabled != dueRemindersEnabled
            || policy.overdueRemindersEnabled != overdueRemindersEnabled
            || policy.playSound != playSound
            || policy.allowSnooze != allowSnooze
            || policy.defaultSnoozeMinutes != defaultSnoozeMinutes
            || policy.maxReminderCount != maxReminderCount
            || policy.escalationIntervalsMinutes != parsedEscalationIntervals
    }

    var reminderPolicy: ReminderPolicy {
        ReminderPolicy(
            isEnabled: remindersEnabled,
            dueRemindersEnabled: dueRemindersEnabled,
            overdueRemindersEnabled: overdueRemindersEnabled,
            playSound: playSound,
            allowSnooze: allowSnooze,
            defaultSnoozeMinutes: defaultSnoozeMinutes,
            maxReminderCount: maxReminderCount,
            escalationIntervalsMinutes: parsedEscalationIntervals,
            routineSlotReminderWindowMinutes: routineWindowMinutes
        )
    }

    var parsedEscalationIntervals: [Int] {
        let values = escalationIntervalsText
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 >= 0 }
        return values.isEmpty ? [0, 30, 120, 720, 1440] : values
    }
}

/// One phase of a `.phased` regimen in the editor (a taper or titration step).
struct PhaseDraft: Identifiable, Hashable {
    var id = UUID()
    var title = ""
    var durationDays = 7
    /// Only meaningful on the last phase: keep going with no end date.
    var isOngoing = false
    var frequency: ScheduleFrequency = .daily
    var intervalDays = 2

    init() {}

    init(phase: RegimenPhase) {
        title = phase.title
        durationDays = phase.durationDays ?? 7
        isOngoing = phase.durationDays == nil
        frequency = phase.recurrenceRule.frequency == .intervalDays ? .intervalDays : .daily
        intervalDays = max(2, phase.recurrenceRule.intervalDays)
    }

    /// Identity-free view for change detection.
    var comparable: [String] {
        [title, isOngoing ? "ongoing" : "\(durationDays)", frequency.rawValue, frequency == .intervalDays ? "\(intervalDays)" : ""]
    }
}

private enum AddMode: String, CaseIterable, Identifiable {
    case lookup
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lookup: "Lookup"
        case .manual: "Manual"
        }
    }
}

struct EditMedicationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appDependencies) private var dependencies

    @FocusState private var focusedField: FocusField?
    @State private var draft: MedicationDraft
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var searchModel: MedicationSearchModel
    @State private var validationMessage: String?
    @State private var addMode: AddMode = .lookup
    @State private var lookupSelection: MedicationSelection?
    /// Once the user touches the missed-dose picker (or when editing an existing med), the
    /// policy stops auto-following the medication kind.
    @State private var missedDosePolicyUserSet: Bool
    /// Likewise the travel choices of a new medication follow its kind and timings
    /// (`TravelSettings.suggested`) until the user picks one.
    @State private var travelChoicesUserSet: Bool
    /// The live example's destination (a zone identifier).
    @State private var exampleDestination: String
    /// Set by Save when the schedule is new or changed: the confirmation step.
    @State private var pendingSummary: ScheduleSummary?

    let medication: Medication?

    enum FocusField: Hashable {
        case displayName
    }

    init(medication: Medication? = nil) {
        self.medication = medication
        _draft = State(initialValue: medication.map { MedicationDraft(medication: $0) } ?? MedicationDraft())
        _searchModel = State(initialValue: MedicationSearchModel(lookupService: AppDependencies.shared.lookupService))
        // Editing preserves the saved policy; a brand-new med lets it follow the kind.
        _missedDosePolicyUserSet = State(initialValue: medication != nil)
        _travelChoicesUserSet = State(initialValue: medication != nil)
        let initialDraft = medication.map { MedicationDraft(medication: $0) } ?? MedicationDraft()
        _exampleDestination = State(initialValue: TravelDestinations.defaultDestination(
            from: TimeZone(identifier: initialDraft.homeTimeZoneIdentifier) ?? .current
        ).identifier)
        if medication == nil {
            var suggested = MedicationDraft()
            suggested.applySuggestedTravelSettings()
            _draft = State(initialValue: suggested)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if medication == nil {
                Picker("Mode", selection: $addMode) {
                    ForEach(AddMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])
                .accessibilityIdentifier(AccessibilityID.addMedicationModeSwitcher)
            }

            Form {
                if medication == nil, addMode == .lookup {
                    MedicationLookupIdentitySection(searchModel: searchModel, selection: $lookupSelection)
                }

                medicationDetailsSection

                Section("Schedule") {
                    DatePicker("Starts on", selection: $draft.anchorDate, displayedComponents: .date)

                    Picker("Frequency", selection: $draft.frequency) {
                        ForEach(ScheduleFrequency.allCases) { frequency in
                            Text(frequency.title).tag(frequency)
                        }
                    }

                    switch draft.frequency {
                    case .intervalDays:
                        Stepper("Every \(draft.intervalDays) days", value: $draft.intervalDays, in: 1...30)
                    case .weekly:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Weekdays")
                                .font(.subheadline.weight(.medium))
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                                ForEach(1...7, id: \.self) { weekday in
                                    Button {
                                        toggleWeekday(weekday)
                                    } label: {
                                        Text(AppFormatting.weekdayTitle(weekday).prefix(3))
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(draft.weekdays.contains(weekday) ? .accentColor : .gray.opacity(0.5))
                                    .accessibilityLabel(AppFormatting.weekdayTitle(weekday))
                                    .accessibilityValue(draft.weekdays.contains(weekday) ? "Selected" : "Not selected")
                                }
                            }
                        }
                    case .monthly:
                        Stepper("Day \(draft.dayOfMonth)", value: $draft.dayOfMonth, in: 1...31)
                    case .cycle:
                        Stepper("\(draft.cycleOnDays) days on", value: $draft.cycleOnDays, in: 1...30)
                        Stepper("\(draft.cycleOffDays) days off", value: $draft.cycleOffDays, in: 0...30)
                    case .phased:
                        phasesEditor
                    case .daily:
                        EmptyView()
                    }

                    ForEach($draft.timings) { $timing in
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("When", selection: $timing.kind) {
                                ForEach(TimingAnchorKind.allCases) { kind in
                                    Text(kind.title).tag(kind)
                                }
                            }

                            if timing.kind == .exactTime {
                                DatePicker(
                                    "Time",
                                    selection: exactTimeBinding(for: $timing),
                                    displayedComponents: .hourAndMinute
                                )
                            } else {
                                Toggle("Adjust window for this medication", isOn: customWindowToggle(for: $timing))
                                if timing.customWindow != nil {
                                    DatePicker("From", selection: customWindowBinding(for: $timing, edge: \.start), displayedComponents: .hourAndMinute)
                                    DatePicker("To", selection: customWindowBinding(for: $timing, edge: \.end), displayedComponents: .hourAndMinute)
                                } else {
                                    Text("Uses your \(timing.kind.title) window (\(windowLabel(for: timing.kind))) — edit it in Settings.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        // A schedule needs at least one time; deleting the last one used
                        // to fall back to an invisible "Morning" in the engine.
                        guard draft.timings.count - offsets.count >= 1 else { return }
                        draft.timings.remove(atOffsets: offsets)
                    }
                    .deleteDisabled(draft.timings.count <= 1)

                    Button("Add Another Time") {
                        draft.timings.append(DailyTiming(kind: nextUnusedSlot()))
                    }

                    if draft.timings.contains(where: { $0.kind == .exactTime }) {
                        Stepper(
                            "On time up to \(draft.graceWindowMinutes / 60) hour\(draft.graceWindowMinutes == 60 ? "" : "s") after a specific time",
                            value: $draft.graceWindowMinutes,
                            in: 60...1440,
                            step: 60
                        )
                    }
                }

                travelSections

                Section("Missed dose handling") {
                    Picker("If a dose is late", selection: Binding(
                        get: { draft.missedDosePolicy },
                        set: { newValue in
                            draft.missedDosePolicy = newValue
                            missedDosePolicyUserSet = true
                        }
                    )) {
                        ForEach(MissedDosePolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    Text(draft.missedDosePolicy.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if draft.missedDosePolicy == .rescheduleFromLastDose {
                        DisclosureGroup("Advanced") {
                            Stepper(
                                "Minimum \(draft.minimumIntervalDays) day\(draft.minimumIntervalDays == 1 ? "" : "s") between doses",
                                value: $draft.minimumIntervalDays,
                                in: 1...14
                            )
                            Text("You'll get a heads-up if you log a dose sooner than this after the previous one.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Supply Tracking") {
                    Toggle("Track supply", isOn: $draft.tracksSupply)

                    if draft.tracksSupply {
                        TextField("Unit (\(defaultSupplyUnit))", text: $draft.supplyUnitLabel)

                        Stepper(
                            "Units per container: \(draft.unitsPerContainer)",
                            value: $draft.unitsPerContainer,
                            in: 1...500
                        )
                        Stepper(
                            "On hand now: \(draft.onHandUnits)",
                            value: $draft.onHandUnits,
                            in: 0...5000
                        )
                        Stepper(
                            "Low supply warning at: \(draft.supplyLowThreshold)",
                            value: $draft.supplyLowThreshold,
                            in: 0...5000
                        )
                        Text("A container is one vial/bottle. Taking a dose draws down the open container; use “Log refill” on the medication to add another.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Reminders") {
                    Toggle("Enable reminders", isOn: $draft.remindersEnabled)
                        .accessibilityIdentifier(AccessibilityID.notificationToggle)
                    Toggle("Due reminders", isOn: $draft.dueRemindersEnabled)
                    Toggle("Overdue reminders", isOn: $draft.overdueRemindersEnabled)
                    Toggle("Play sound", isOn: $draft.playSound)
                    Toggle("Allow snooze", isOn: $draft.allowSnooze)
                    Picker("Break through Focus", selection: $draft.timeSensitiveOverride) {
                        Text("Use default").tag(Bool?.none)
                        Text("Always").tag(Bool?.some(true))
                        Text("Never").tag(Bool?.some(false))
                    }
                    Stepper("Default snooze \(draft.defaultSnoozeMinutes) minutes", value: $draft.defaultSnoozeMinutes, in: 5...120, step: 5)
                    Stepper("Maximum reminders \(draft.maxReminderCount)", value: $draft.maxReminderCount, in: 1...12)
                    TextField("Escalation in minutes", text: $draft.escalationIntervalsText)
                        .keyboardType(.numbersAndPunctuation)
                }
            }
        }
        .navigationTitle(medication == nil ? "Add Medication" : "Edit Medication")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveMedication()
                }
                .accessibilityIdentifier(AccessibilityID.saveMedicationButton)
            }
        }
        .task(id: selectedPhotoItem) {
            guard let selectedPhotoItem else { return }
            if let data = try? await selectedPhotoItem.loadTransferable(type: Data.self) {
                // Store a small JPEG, not the full camera image: the artwork view decodes
                // it on every render of every row that shows this medication.
                draft.imageData = PhotoDownscaler.thumbnailData(from: data) ?? data
            }
        }
        .onChange(of: lookupSelection) { _, newValue in
            applyLookupSelection(newValue)
        }
        .onChange(of: draft.kind) { _, newKind in
            // A brand-new med's missed-dose policy follows the kind until the user picks
            // one explicitly (injection → reschedule, oral → keep).
            if !missedDosePolicyUserSet {
                draft.missedDosePolicy = MissedDosePolicy.defaultFor(kind: newKind)
            }
            followSuggestedTravelSettings()
        }
        .onChange(of: draft.timings.map(\.kind)) { _, _ in followSuggestedTravelSettings() }
        .onChange(of: draft.timeSensitiveOverride) { _, _ in followSuggestedTravelSettings() }
        .sheet(isPresented: Binding(
            get: { pendingSummary != nil },
            set: { if !$0 { pendingSummary = nil } }
        )) {
            NavigationStack {
                if let summary = pendingSummary {
                    ScheduleConfirmationView(
                        name: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        summary: summary,
                        onSave: {
                            pendingSummary = nil
                            performSave()
                        },
                        onKeepEditing: { pendingSummary = nil }
                    )
                }
            }
            .presentationDetents([.large])
        }
    }

    @ViewBuilder
    private var medicationDetailsSection: some View {
        Section("Medication") {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Label(draft.imageData == nil ? "Add Photo" : "Change Photo", systemImage: "photo")
            }

            if let imageData = draft.imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(.rect(cornerRadius: 16))
                    .accessibilityHidden(true)
            }

            TextField("Custom display name", text: $draft.displayName)
                .textInputAutocapitalization(.words)
                .focused($focusedField, equals: .displayName)
                .accessibilityIdentifier(AccessibilityID.saveMedicationButton + ".name")

            TextField("Clinical or real medication name", text: $draft.canonicalName)
                .textInputAutocapitalization(.words)

            if let selectedStrengthAndForm = draft.selectedStrengthAndForm {
                Text(selectedStrengthAndForm)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("Notes", text: $draft.notes, axis: .vertical)
                .lineLimit(3...6)

            HStack(spacing: 8) {
                ForEach(MedicationKind.allCases) { kind in
                    Button {
                        draft.kind = kind
                    } label: {
                        Label(kind.title, systemImage: kind.symbolName)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(draft.kind == kind ? .accentColor : .gray.opacity(0.5))
                    .accessibilityValue(draft.kind == kind ? "Selected" : "Not selected")
                }
            }

            Toggle("Take with food", isOn: $draft.takeWithFood)

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Validation error. \(validationMessage)")
            }
        }
    }

    private func applyLookupSelection(_ selection: MedicationSelection?) {
        guard let selection else { return }

        draft.canonicalName = selection.result.canonicalName
        draft.normalizedMedicationCode = selection.variant.rxcui ?? selection.result.rxNormCode ?? ""
        draft.selectedStrengthAndForm = selection.variant.strengthAndForm.isEmpty ? nil : selection.variant.strengthAndForm
        draft.kind = inferredMedicationKind(fromRouteSummary: selection.result.routeSummary)
        draft.drugLabelInfo = nil
        if draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.displayName = selection.result.displayName
        }

        let rxcui = selection.variant.rxcui ?? selection.result.rxNormCode
        let genericName = selection.result.canonicalName
        Task {
            let info = await DrugInfoService.fetchLabel(rxcui: rxcui, genericName: genericName)
            // The user may have picked a different variant while this was in flight —
            // don't let a stale fetch clobber a newer selection.
            guard lookupSelection == selection else { return }
            draft.drugLabelInfo = info
        }
    }

    private func followSuggestedTravelSettings() {
        guard !travelChoicesUserSet else { return }
        draft.applySuggestedTravelSettings()
    }

    private var homeZone: TimeZone {
        TimeZone(identifier: draft.homeTimeZoneIdentifier) ?? .current
    }

    /// "When you travel" (decided 2026-10-23, branch `travel-options`): the home zone and
    /// the three choices — the clock, long trips & date lines, landing during a dose —
    /// each option with its one-line explanation, then a live example computed by the
    /// engine on a trip to a destination the user can change.
    @ViewBuilder
    private var travelSections: some View {
        let follows = draft.travelSettings.anyFollows(draft.timings)
        Section {
            homeTimeZoneRow
        } header: {
            Text(String(localized: "When you travel", comment: "Edit: the travel section's title"))
        } footer: {
            Text(String(localized: "Three choices decide what your doses do away from home. The example below shows them on a trip.", comment: "Edit: travel section footer"))
        }

        Section(String(localized: "Clock", comment: "Edit: the travel clock choice")) {
            Picker(String(localized: "Clock", comment: "Edit: the travel clock choice"), selection: Binding<TravelTimePolicy?>(
                get: { draft.travelPolicy ?? draft.defaultTravelPolicy },
                set: { draft.travelPolicy = $0; travelChoicesUserSet = true }
            )) {
                if draft.defaultTravelPolicy == nil {
                    optionLabel(
                        String(localized: "Automatic", comment: "Travel setting: named times follow, specific times stay home"),
                        String(localized: "Named times (Morning, Evening…) follow you; specific times stay on home time.", comment: "Explains the Automatic travel setting")
                    )
                    .tag(TravelTimePolicy?.none)
                }
                ForEach(TravelTimePolicy.allCases) { policy in
                    optionLabel(policy.title, policy.explanation).tag(TravelTimePolicy?.some(policy))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.travelPolicyPicker)
        }

        Section {
            Picker(String(localized: "Long trips & date lines", comment: "Edit: the travel spacing choice"), selection: Binding(
                get: { draft.travelSpacing },
                set: { draft.travelSpacing = $0; travelChoicesUserSet = true }
            )) {
                ForEach(TravelSpacing.allCases) { spacing in
                    optionLabel(spacing.title(hours: draft.effectiveTravelMinimumHours), spacing.explanation(hours: draft.effectiveTravelMinimumHours))
                        .tag(spacing)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.travelSpacingPicker)

            if draft.travelSpacing == .minimumHours {
                Stepper(
                    String(localized: "At least \(draft.effectiveTravelMinimumHours) hours", comment: "Edit: the minimum hours between doses"),
                    value: Binding(
                        get: { draft.effectiveTravelMinimumHours },
                        set: { draft.travelMinimumHours = $0; draft.travelMinimumHoursSet = true; travelChoicesUserSet = true }
                    ),
                    in: 1...max(24, TravelSettings.nominalHours(for: draft.recurrenceRule))
                )
                .accessibilityIdentifier(AccessibilityID.travelHoursStepper)
            }
        } header: {
            Text(String(localized: "Long trips & date lines", comment: "Edit: the travel spacing choice"))
        } footer: {
            if !follows {
                Text(String(localized: "Doses on home time never move, so this only matters for doses that follow you.", comment: "Edit: travel spacing footer when nothing follows"))
            }
        }
        .disabled(!follows)

        Section {
            Picker(String(localized: "Landing during a dose", comment: "Edit: the travel landing choice"), selection: Binding(
                get: { draft.travelLanding },
                set: { draft.travelLanding = $0; travelChoicesUserSet = true }
            )) {
                ForEach(TravelLanding.allCases) { landing in
                    optionLabel(landing.title, landing.explanation).tag(landing)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.travelLandingPicker)
        } header: {
            Text(String(localized: "Landing during a dose", comment: "Edit: the travel landing choice"))
        } footer: {
            if !follows {
                Text(String(localized: "Doses on home time keep their times when you land.", comment: "Edit: travel landing footer when nothing follows"))
            }
        }
        .disabled(!follows)

        Section(String(localized: "Example", comment: "Edit: the live travel example")) {
            NavigationLink {
                TravelDestinationPickerView(selection: $exampleDestination, home: homeZone)
            } label: {
                LabeledContent(
                    String(localized: "Trip to", comment: "Edit: the example's destination"),
                    value: SlotClockLabel.placeName(of: TimeZone(identifier: exampleDestination) ?? .current)
                )
            }
            .accessibilityIdentifier(AccessibilityID.travelDestinationRow)

            if let example = travelExample {
                VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
                    Text(example.heading)
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(example.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Theme.Spacing.s1)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.travelExample)
            }
        }
    }

    /// The example for the form as it stands, from tomorrow on the home clock.
    private var travelExample: TravelExample? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = homeZone
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        return TravelExample.make(
            schedule: draft.exampleSchedule,
            destination: TimeZone(identifier: exampleDestination) ?? .current,
            preferences: dependencies.preferencesStore.preferences,
            from: max(tomorrow, calendar.startOfDay(for: draft.anchorDate))
        )
    }

    /// An inline picker option: the choice and its one-line explanation.
    private func optionLabel(_ title: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Home time zone  New York (Eastern Time) ›" — the clock every time above is on.
    /// Away from it, a one-tap switch to the device's zone (a new regimen version: future
    /// doses move to the same wall-clock times here, history stays as it was).
    @ViewBuilder
    private var homeTimeZoneRow: some View {
        let home = homeZone
        NavigationLink {
            TimeZonePickerView(selection: $draft.homeTimeZoneIdentifier)
        } label: {
            LabeledContent("Home time zone", value: ZonedTimeFormatter.displayName(of: home))
        }
        .accessibilityIdentifier(AccessibilityID.homeTimeZoneRow)

        if home.secondsFromGMT() != TimeZone.current.secondsFromGMT() {
            VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
                Text(String(localized: "The schedule's times are on this clock. While you travel, each dose follows the choices below.", comment: "Edit: under the home time zone, away from it"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Use This Device's Time Zone (\(ZonedTimeFormatter.displayName(of: .current)))") {
                    draft.homeTimeZoneIdentifier = TimeZone.current.identifier
                }
                .font(.footnote.weight(.semibold))
            }
        }
    }

    private var defaultSupplyUnit: String {
        draft.kind == .injection ? "doses" : "tablets"
    }

    private func nextUnusedSlot() -> TimingAnchorKind {
        let used = Set(draft.timings.map(\.kind))
        return [TimingAnchorKind.morning, .noon, .evening, .bedtime, .night].first { !used.contains($0) } ?? .exactTime
    }

    @ViewBuilder
    private var phasesEditor: some View {
        Text("Each phase runs for a number of days, one after another from the start date, at the times below.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        ForEach($draft.phases) { $phase in
            let index = draft.phases.firstIndex { $0.id == phase.id } ?? 0
            let isLast = index == draft.phases.count - 1
            VStack(alignment: .leading, spacing: 8) {
                TextField("Phase \(index + 1) name", text: $phase.title)
                Picker("Doses", selection: $phase.frequency) {
                    Text("Every day").tag(ScheduleFrequency.daily)
                    Text("Every few days").tag(ScheduleFrequency.intervalDays)
                }
                if phase.frequency == .intervalDays {
                    Stepper("Every \(phase.intervalDays) days", value: $phase.intervalDays, in: 2...30)
                }
                if isLast {
                    Toggle("Continue with no end", isOn: $phase.isOngoing)
                }
                if !(isLast && phase.isOngoing) {
                    Stepper("Lasts \(phase.durationDays) day\(phase.durationDays == 1 ? "" : "s")", value: $phase.durationDays, in: 1...365)
                }
            }
        }
        .onDelete { offsets in
            draft.phases.remove(atOffsets: offsets)
        }
        Button("Add Phase") {
            draft.phases.append(PhaseDraft())
        }
    }

    private func toggleWeekday(_ weekday: Int) {
        if draft.weekdays.contains(weekday) {
            // Keep at least one day selected ("Weekly on  at Morning" otherwise).
            guard draft.weekdays.count > 1 else { return }
            draft.weekdays.remove(weekday)
        } else {
            draft.weekdays.insert(weekday)
        }
    }

    private func exactTimeBinding(for timing: Binding<DailyTiming>) -> Binding<Date> {
        Binding<Date>(
            get: {
                (timing.wrappedValue.exactTime ?? timing.wrappedValue.overrideTime ?? ClockTime(hour: 8, minute: 0))
                    .applying(to: .now, calendar: .current)
            },
            set: { timing.wrappedValue.exactTime = ClockTime(date: $0) }
        )
    }

    private func windowLabel(for kind: TimingAnchorKind) -> String {
        let window = dependencies.preferencesStore.defaultWindow(for: kind)
        return "\(window.start.displayText)–\(window.end.displayText)"
    }

    private func customWindowToggle(for timing: Binding<DailyTiming>) -> Binding<Bool> {
        Binding<Bool>(
            get: { timing.wrappedValue.customWindow != nil },
            set: { isOn in
                timing.wrappedValue.customWindow = isOn
                    ? dependencies.preferencesStore.defaultWindow(for: timing.wrappedValue.kind)
                    : nil
            }
        )
    }

    private func customWindowBinding(for timing: Binding<DailyTiming>, edge: WritableKeyPath<DoseWindow, ClockTime>) -> Binding<Date> {
        Binding<Date>(
            get: {
                let window = timing.wrappedValue.customWindow ?? dependencies.preferencesStore.defaultWindow(for: timing.wrappedValue.kind)
                return window[keyPath: edge].applying(to: .now, calendar: .current)
            },
            set: { newValue in
                var window = timing.wrappedValue.customWindow ?? dependencies.preferencesStore.defaultWindow(for: timing.wrappedValue.kind)
                window[keyPath: edge] = ClockTime(date: newValue)
                if window.end.hour * 60 + window.end.minute < window.start.hour * 60 + window.start.minute {
                    if edge == \DoseWindow.start { window.end = window.start } else { window.start = window.end }
                }
                timing.wrappedValue.customWindow = window
            }
        )
    }

    /// Save: a new or changed schedule first shows "How this schedule works"
    /// (`ScheduleConfirmationView`); anything else saves at once.
    private func saveMedication() {
        guard validate() else { return }
        if medication == nil || draft.scheduleDiffers(from: medication?.regimens.active) {
            pendingSummary = ScheduleSummary(draft.summaryInputs, preferences: dependencies.preferencesStore.preferences)
        } else {
            performSave()
        }
    }

    private func validate() -> Bool {
        let trimmedName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Enter a custom display name."
            focusedField = .displayName
            return false
        }
        guard draft.frequency != .phased || !draft.phases.isEmpty else {
            validationMessage = "Add at least one phase, or pick another frequency."
            return false
        }
        validationMessage = nil
        return true
    }

    private func performSave() {
        guard validate() else { return }
        let trimmedName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        let medication = medication ?? Medication(displayName: trimmedName)
        medication.displayName = trimmedName
        medication.canonicalName = draft.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        medication.normalizedMedicationCode = draft.normalizedMedicationCode.nilIfEmpty
        medication.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        medication.imageData = draft.imageData
        medication.isActive = true
        medication.kind = draft.kind
        medication.takeWithFood = draft.takeWithFood
        medication.timeSensitiveNotifications = draft.timeSensitiveOverride
        medication.selectedStrengthAndForm = draft.selectedStrengthAndForm
        medication.drugLabelInfo = draft.drugLabelInfo

        if draft.tracksSupply {
            let perContainer = max(1, draft.unitsPerContainer)
            // An empty unit used to switch tracking off silently (tracking means a
            // non-empty unit); fall back to the placeholder the field showed.
            medication.supplyUnitLabel = draft.supplyUnitLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? defaultSupplyUnit
            medication.unitsPerContainer = perContainer
            medication.supplyLowThreshold = draft.supplyLowThreshold
            // Preserve the existing container breakdown when the on-hand total is unchanged
            // (so taking doses hasn't been silently re-bucketed); otherwise rebuild it as a
            // partial "open" container followed by full ones.
            if !(medication.isTrackingSupply && draft.onHandUnits == medication.totalRemaining) {
                medication.supplyContainers = Self.containers(forOnHand: draft.onHandUnits, perContainer: perContainer)
            }
        } else {
            medication.supplyUnitLabel = nil
        }

        if self.medication == nil {
            modelContext.insert(medication)
        }

        let currentRegimen = medication.regimens.active
        if draft.scheduleDiffers(from: currentRegimen) {
            for existingRegimen in medication.regimens where existingRegimen.isActive {
                existingRegimen.isActive = false
            }

            let newVersion = (medication.regimens.map(\.version).max() ?? 0) + 1
            let regimen = MedicationRegimen(
                version: newVersion,
                anchorDate: draft.anchorDate,
                timeZoneIdentifier: draft.homeTimeZoneIdentifier,
                recurrenceRule: draft.recurrenceRule,
                timings: draft.timings,
                graceWindowMinutes: draft.graceWindowMinutes,
                missedDosePolicy: draft.missedDosePolicy,
                minimumIntervalHours: draft.minimumIntervalHours,
                travelPolicy: draft.travelPolicy,
                travelSpacing: draft.travelSpacing,
                travelMinimumHours: draft.travelMinimumHoursSet ? draft.travelMinimumHours : nil,
                travelLanding: draft.travelLanding,
                medication: medication
            )
            for phase in draft.makePhases() {
                phase.regimen = regimen
                regimen.phases.append(phase)
                modelContext.insert(phase)
            }
            let reminderPolicy = draft.reminderPolicy
            reminderPolicy.regimen = regimen
            regimen.reminderPolicies.append(reminderPolicy)
            medication.regimens.append(regimen)

            modelContext.insert(regimen)
            modelContext.insert(reminderPolicy)
        } else if let currentRegimen, draft.reminderPolicyDiffers(from: currentRegimen.activeReminderPolicy) {
            // Reminder settings don't change which doses exist — no new version, just a
            // newer policy (`activeReminderPolicy` is the most recent one).
            let reminderPolicy = draft.reminderPolicy
            reminderPolicy.regimen = currentRegimen
            currentRegimen.reminderPolicies.append(reminderPolicy)
            modelContext.insert(reminderPolicy)
        }

        try? modelContext.save()
        dependencies.refreshSchedules(context: modelContext)

        // Prime the notification permission at the moment it makes obvious sense — the
        // user just created a schedule that needs reminders. iOS shows the system prompt
        // only once; later calls are no-ops. (Not under UI tests: the system alert
        // would sit on top of the next screen.)
        if dependencies.notificationScheduler.authorizationStatus == .notDetermined, !LaunchOptions.isUITesting {
            Task { await dependencies.notificationScheduler.requestAuthorization() }
        }

        dismiss()
    }

    /// Split a total on-hand count into containers: a partial open container first
    /// (the remainder currently in use), then full containers.
    private static func containers(forOnHand onHand: Int, perContainer: Int) -> [Int] {
        guard onHand > 0 else { return [] }
        let per = max(1, perContainer)
        var result: [Int] = []
        let remainder = onHand % per
        if remainder > 0 { result.append(remainder) }
        result.append(contentsOf: Array(repeating: per, count: onHand / per))
        return result
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
