import PhotosUI
import SwiftData
import SwiftUI

private struct MedicationDraft {
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
    var frequency: ScheduleFrequency = .daily
    var intervalDays = 1
    var weekdays = Set<Int>([2])
    var dayOfMonth = 1
    var cycleOnDays = 1
    var cycleOffDays = 0
    var timings: [DailyTiming] = [DailyTiming(kind: .morning)]
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
            frequency = regimen.recurrenceRule.frequency
            intervalDays = regimen.recurrenceRule.intervalDays
            weekdays = Set(regimen.recurrenceRule.weekdays)
            dayOfMonth = regimen.recurrenceRule.dayOfMonth
            cycleOnDays = regimen.recurrenceRule.cycleOnDays
            cycleOffDays = regimen.recurrenceRule.cycleOffDays
            timings = regimen.timings.isEmpty ? [DailyTiming(kind: .morning)] : regimen.timings
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
        _draft = State(initialValue: medication.map(MedicationDraft.init) ?? MedicationDraft())
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
                    DatePicker("Anchor date", selection: $draft.anchorDate, displayedComponents: .date)

                    Picker("Frequency", selection: $draft.frequency) {
                        ForEach([ScheduleFrequency.daily, .intervalDays, .weekly, .monthly, .cycle], id: \.self) { frequency in
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
                    case .daily, .phased:
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
                        draft.timings.remove(atOffsets: offsets)
                    }

                    Button("Add Another Time") {
                        draft.timings.append(DailyTiming(kind: .morning))
                    }

                    Stepper(
                        "Grace window \(draft.graceWindowMinutes / 60) hours",
                        value: $draft.graceWindowMinutes,
                        in: 60...1440,
                        step: 60
                    )
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
                        TextField("Unit (e.g. tablets, doses)", text: $draft.supplyUnitLabel)

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
                    Stepper("Routine slot window \(draft.routineWindowMinutes) minutes", value: $draft.routineWindowMinutes, in: 30...240, step: 15)
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
                draft.imageData = data
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

    private func toggleWeekday(_ weekday: Int) {
        if draft.weekdays.contains(weekday) {
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
            medication.supplyUnitLabel = draft.supplyUnitLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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

        for existingRegimen in medication.regimens where existingRegimen.isActive {
            existingRegimen.isActive = false
        }

        let newVersion = (medication.regimens.map(\.version).max() ?? 0) + 1
        let regimen = MedicationRegimen(
            version: newVersion,
            anchorDate: draft.anchorDate,
            recurrenceRule: draft.recurrenceRule,
            timings: draft.timings,
            graceWindowMinutes: draft.graceWindowMinutes,
            missedDosePolicy: draft.missedDosePolicy,
            minimumIntervalHours: draft.missedDosePolicy == .rescheduleFromLastDose ? draft.minimumIntervalDays * 24 : nil,
            medication: medication
        )
        let reminderPolicy = draft.reminderPolicy
        reminderPolicy.regimen = regimen
        regimen.reminderPolicies.append(reminderPolicy)
        medication.regimens.append(regimen)

        modelContext.insert(regimen)
        modelContext.insert(reminderPolicy)

        try? modelContext.save()
        dependencies.refreshSchedules(context: modelContext)

        // Prime the notification permission at the moment it makes obvious sense — the
        // user just created a schedule that needs reminders. iOS shows the system prompt
        // only once; later calls are no-ops.
        if dependencies.notificationScheduler.authorizationStatus == .notDetermined {
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
