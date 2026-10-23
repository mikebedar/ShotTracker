import SwiftUI

/// Picks a medication's home time zone — the clock its schedule's times are on. Pushed
/// from the edit form; the device's own zone and the current choice sit on top, every
/// other zone is a search away.
struct TimeZonePickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var deviceZone: TimeZone { .current }

    private var results: [TimeZone] {
        let zones = TimeZone.knownTimeZoneIdentifiers.compactMap(TimeZone.init(identifier:))
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return zones }
        return zones.filter { zone in
            zone.identifier.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(trimmed)
                || ZonedTimeFormatter.displayName(of: zone).localizedCaseInsensitiveContains(trimmed)
                || (zone.abbreviation() ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section("This device") {
                    row(for: deviceZone)
                }
                if selection != deviceZone.identifier, let current = TimeZone(identifier: selection) {
                    Section("Current home zone") {
                        row(for: current)
                    }
                }
            }
            Section(query.isEmpty ? "All time zones" : "Results") {
                ForEach(results, id: \.identifier) { zone in
                    row(for: zone)
                }
            }
        }
        .searchable(text: $query, prompt: "City or zone")
        .navigationTitle("Home Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for zone: TimeZone) -> some View {
        Button {
            selection = zone.identifier
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ZonedTimeFormatter.displayName(of: zone))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(Self.offsetText(of: zone))
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

    /// "GMT−4 · 8:05 AM now".
    private static func offsetText(of zone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = zone
        return "\(ZonedTimeFormatter.abbreviation(of: zone, at: .now)) · \(Date.now.formatted(style)) now"
    }
}
