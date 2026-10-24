import SwiftUI

/// The live travel example's destinations: a short list of cities around the world,
/// searchable by city or zone name.
enum TravelDestinations {
    static let identifiers = [
        "Pacific/Honolulu", "America/Anchorage", "America/Los_Angeles", "America/Denver",
        "America/Chicago", "America/New_York", "America/Sao_Paulo", "Europe/London",
        "Europe/Paris", "Africa/Cairo", "Africa/Johannesburg", "Europe/Moscow", "Asia/Dubai",
        "Asia/Kolkata", "Asia/Bangkok", "Asia/Singapore", "Asia/Hong_Kong", "Asia/Tokyo",
        "Australia/Sydney", "Pacific/Auckland",
    ]

    static var zones: [TimeZone] {
        identifiers.compactMap(TimeZone.init(identifier:))
    }

    /// A destination far enough from `home` to show something: Paris from the Americas,
    /// Tokyo from Europe and Africa, New York from Asia and the Pacific (and Tokyo from
    /// New York's own neighbours east of it, Paris when home is already Tokyo's side).
    static func defaultDestination(from home: TimeZone, at date: Date = .now) -> TimeZone {
        let hours = home.secondsFromGMT(for: date) / 3600
        let identifier: String
        if hours <= -3 {
            identifier = "Europe/Paris"
        } else if hours <= 4 {
            identifier = "Asia/Tokyo"
        } else {
            identifier = "America/New_York"
        }
        let zone = TimeZone(identifier: identifier) ?? .gmt
        if zone.secondsFromGMT(for: date) == home.secondsFromGMT(for: date) {
            return TimeZone(identifier: "Asia/Tokyo") ?? zone
        }
        return zone
    }
}

/// Picks the example trip's destination.
struct TravelDestinationPickerView: View {
    @Binding var selection: String
    let home: TimeZone
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [TimeZone] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return TravelDestinations.zones }
        return TravelDestinations.zones.filter { zone in
            SlotClockLabel.placeName(of: zone).localizedCaseInsensitiveContains(trimmed)
                || ZonedTimeFormatter.displayName(of: zone).localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        List(results, id: \.identifier) { zone in
            Button {
                selection = zone.identifier
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SlotClockLabel.placeName(of: zone))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Text(difference(of: zone))
                            .font(.footnote)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    Spacer()
                    if zone.identifier == selection {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Theme.Color.accentStrong)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .accessibilityAddTraits(zone.identifier == selection ? .isSelected : [])
        }
        .searchable(text: $query, prompt: String(localized: "City", comment: "Search prompt for the example's destination"))
        .navigationTitle(String(localized: "Trip To", comment: "Title of the example destination picker"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "6 hours ahead of New York", "same time as New York".
    private func difference(of zone: TimeZone) -> String {
        let seconds = zone.secondsFromGMT() - home.secondsFromGMT()
        let place = SlotClockLabel.placeName(of: home)
        guard seconds != 0 else {
            return String(localized: "Same time as \(place)", comment: "Destination picker: no time difference")
        }
        let amount = SnoozeWording.duration(minutes: abs(seconds) / 60)
        return seconds > 0
            ? String(localized: "\(amount) ahead of \(place)", comment: "Destination picker: ahead of home")
            : String(localized: "\(amount) behind \(place)", comment: "Destination picker: behind home")
    }
}
