import SwiftUI

/// A single logged dose action. Shared by the global History tab and a medication's
/// own history drill-down. `showMedicationName` is off in the per-med view where the
/// name is redundant.
struct DoseEventRow: View {
    let event: DoseEvent
    var showMedicationName: Bool = true

    @Environment(\.dayParts) private var dayParts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showMedicationName {
                Text(event.medication?.displayName ?? "Medication")
                    .font(.headline)
                if let canonicalName = event.medication.flatMap(AppFormatting.medicationSubtitle(for:)) {
                    Text(canonicalName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            // "Taken 45 min late · snoozed 30 min", "Snoozed 20 min" — see `SnoozeWording`.
            Text(title)
                .font(.subheadline.weight(.medium))
                .accessibilityLabel(SnoozeWording.spoken(title))
            // Away from home: the slot on the clock it was taken on, "Morning (Paris) · Home: Night".
            if let slot {
                Text(slotLine(slot))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(spokenSlotLine(slot))
            }
            Text(times.dateTime(event.loggedAt))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(event.loggedAt.formatted(date: .abbreviated, time: .omitted)), \(times.spokenTime(event.loggedAt))")
            if !event.note.isEmpty {
                Text(event.note)
                    .font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        SnoozeWording.eventTitle(for: event)
    }

    private var home: TimeZone? {
        event.scheduledDose?.homeTimeZone ?? event.medication?.homeTimeZone()
    }

    /// The slot as it read where the dose was logged — nil at home or for a specific time.
    private var slot: SlotClockLabel? {
        guard let dose = event.scheduledDose else { return nil }
        return DoseClockText(dose: dose, medication: event.medication, dayParts: dayParts, device: event.timeZone ?? .current).awaySlot
    }

    private func slotLine(_ slot: SlotClockLabel) -> String {
        guard let detail = slot.shortDetail else { return slot.title }
        return "\(slot.title) · \(detail)"
    }

    private func spokenSlotLine(_ slot: SlotClockLabel) -> String {
        guard let detail = slot.spokenShortDetail else { return slot.spokenTitle }
        return "\(slot.spokenTitle); \(detail)"
    }

    /// The time on the clock the dose was logged on, beside the home one: "Oct 23 at
    /// 2:05 AM home · 8:05 AM here" in Paris, "… · 8:05 AM Paris" once back home. An event
    /// logged at home (or before zones were recorded) reads as before: home, plus here
    /// when the device is elsewhere.
    private var times: ZonedTimeFormatter {
        let date = event.loggedAt
        if let logged = event.timeZone, let home,
           logged.secondsFromGMT(for: date) != home.secondsFromGMT(for: date) {
            let isHere = logged.secondsFromGMT(for: date) == TimeZone.current.secondsFromGMT(for: date)
            return ZonedTimeFormatter(home: home, local: logged, localName: isHere ? nil : SlotClockLabel.placeName(of: logged, at: date))
        }
        return ZonedTimeFormatter(home: home)
    }
}
