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
    /// "When travelling": nil = by timing kind (named slots follow the device, specific
    /// times stay home). Changing what it means for any timing is a schedule change.
    var travelPolicy: TravelTimePolicy?
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

    /// What "When travelling" means for each timing. Picking the default explicitly
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

                    homeTimeZoneRow

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

    /// "Home time zone  New York (Eastern Time) ›" — the clock every time below is on.
    /// Away from it, a one-tap switch to the device's zone (a new regimen version: future
    /// doses move to the same wall-clock times here, history stays as it was).
    @ViewBuilder
    private var homeTimeZoneRow: some View {
        let home = TimeZone(identifier: draft.homeTimeZoneIdentifier) ?? .current
        NavigationLink {
            TimeZonePickerView(selection: $draft.homeTimeZoneIdentifier)
        } label: {
            LabeledContent("Home time zone", value: ZonedTimeFormatter.displayName(of: home))
        }
        .accessibilityIdentifier(AccessibilityID.homeTimeZoneRow)

        if home.secondsFromGMT() != TimeZone.current.secondsFromGMT() {
            VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
                Text(String(localized: "The times below are on this clock. While you travel, each dose follows the setting below.", comment: "Edit: under the home time zone, away from it"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Use This Device's Time Zone (\(ZonedTimeFormatter.displayName(of: .current)))") {
                    draft.homeTimeZoneIdentifier = TimeZone.current.identifier
                }
                .font(.footnote.weight(.semibold))
            }
        }

        travelPolicyRow
    }

    /// "When travelling: Follows me / Stays on home time". The default depends on the
    /// timings (named slots follow, specific times stay); a mix offers "Automatic".
    @ViewBuilder
    private var travelPolicyRow: some View {
        let defaultPolicy = draft.defaultTravelPolicy
        Picker(String(localized: "When travelling", comment: "Edit: the travel setting's label"), selection: Binding<TravelTimePolicy?>(
            get: { draft.travelPolicy ?? defaultPolicy },
            set: { draft.travelPolicy = $0 }
        )) {
            if defaultPolicy == nil {
                Text(String(localized: "Automatic", comment: "Travel setting: named times follow, specific times stay home")).tag(TravelTimePolicy?.none)
            }
            ForEach(TravelTimePolicy.allCases) { policy in
                Text(policy.title).tag(TravelTimePolicy?.some(policy))
            }
        }
        .accessibilityIdentifier(AccessibilityID.travelPolicyPicker)

        Text(travelPolicyExplanation)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var travelPolicyExplanation: String {
        if let policy = draft.travelPolicy ?? draft.defaultTravelPolicy {
            return policy.explanation
        }
        return String(localized: "Named times (Morning, Evening…) move to the local clock when you travel; specific times stay at their home times and remind you at that moment.", comment: "Explains the Automatic travel setting")
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

    private func saveMedication() {
        let trimmedName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationMessage = "Enter a custom display name."
            focusedField = .displayName
            return
        }
        guard draft.frequency != .phased || !draft.phases.isEmpty else {
            validationMessage = "Add at least one phase, or pick another frequency."
            return
        }

        validationMessage = nil

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
