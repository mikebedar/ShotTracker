import AtelierTheme
import SwiftUI
import WidgetKit

// MARK: - Entry view (family switch)

struct TodayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TodayEntry

    var body: some View {
        let resolved = entry.snapshot.resolvedItems(at: entry.date)
        let showNames = entry.snapshot.showMedicationNames
        let dayParts = entry.snapshot.dayParts ?? .standard

        Group {
            switch family {
            case .systemSmall:
                SmallWidgetView(items: resolved, showNames: showNames, dayParts: dayParts)
            case .systemLarge:
                ListWidgetView(items: resolved, showNames: showNames, maxRows: 7, dayParts: dayParts)
            default:
                ListWidgetView(items: resolved, showNames: showNames, maxRows: 3, dayParts: dayParts)
            }
        }
        .widgetURL(WidgetShared.todayDeepLink)
        .containerBackground(for: .widget) { Rectangle().fill(.surfaceRaised) }
        // The app's theme (AtelierTheme only): tones, text roles, spacing.
        .atelierTheme(entry.theme)
    }
}

// MARK: - Small: most-urgent dose

struct SmallWidgetView: View {
    let items: [ResolvedWidgetItem]
    let showNames: Bool
    var dayParts: DayParts = .standard

    var body: some View {
        if let top = items.first {
            Column(spacing: .s) {
                HStack {
                    Label {
                        Text(WidgetStatusStyle.title(top.status))
                            .textRole(.caption.weighted(.semibold))
                    } icon: {
                        Image(systemName: WidgetStatusStyle.symbol(top.status))
                    }
                    .foregroundStyle(WidgetStatusStyle.color(top.status))
                    .widgetAccentable()
                    Spacer()
                    if items.count > 1 {
                        Text("+\(items.count - 1)")
                            .textRole(.meta)
                    }
                }

                Spacer(minLength: 0)

                if showNames {
                    Text(top.item.displayName)
                        .textRole(.widgetName)
                        .lineLimit(2)
                } else {
                    Image(systemName: top.item.kindSymbol)
                        .font(.title2)
                        .foregroundStyle(WidgetStatusStyle.color(top.status))
                        .widgetAccentable()
                }

                Text(top.item.timeText(dayParts: dayParts))
                    .textRole(.widgetTime)
                    .minimumScaleFactor(0.75)
                // Away from home: the other clock's time, "Home: Night · by 6:00 AM".
                if let detail = top.item.detailText(dayParts: dayParts) {
                    Text(detail)
                        .textRole(.meta.colored(.secondary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            AllDoneView(compact: true)
        }
    }
}

// MARK: - Medium / Large: a list

struct ListWidgetView: View {
    let items: [ResolvedWidgetItem]
    let showNames: Bool
    let maxRows: Int
    var dayParts: DayParts = .standard

    private var overdueCount: Int { items.filter { $0.status == .overdue }.count }

    var body: some View {
        if items.isEmpty {
            AllDoneView(compact: false)
        } else {
            Column(spacing: .s) {
                HStack {
                    Text("Today's Doses")
                        .textRole(.widgetName)
                    Spacer()
                    if overdueCount > 0 {
                        Text("\(overdueCount) overdue")
                            .textRole(.caption.weighted(.semibold))
                            .foregroundStyle(.tone(.danger, .onFill))
                            .padding(.horizontal, .s)
                            .padding(.vertical, .xxs)
                            .background(Capsule().fill(.tone(.danger, .fill)))
                            .widgetAccentable()
                    }
                }

                ForEach(items.prefix(maxRows)) { resolved in
                    DoseRow(resolved: resolved, showNames: showNames, dayParts: dayParts)
                }

                if items.count > maxRows {
                    Text("+\(items.count - maxRows) more")
                        .textRole(.helper)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Row

struct DoseRow: View {
    let resolved: ResolvedWidgetItem
    let showNames: Bool
    var dayParts: DayParts = .standard

    private var item: WidgetDoseItem { resolved.item }
    private var color: ThemeColor { WidgetStatusStyle.color(resolved.status) }

    var body: some View {
        Row(spacing: .m) {
            if showNames {
                AvatarView(letter: item.avatarLetter, hue: item.avatarHue)
            } else {
                Image(systemName: item.kindSymbol)
                    .font(.body)
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28) // ds-allow: the avatar's size, matched
                    .background(Circle().fill(.tone(resolved.status.tone, .subtleFill)))
                    .widgetAccentable()
            }

            Column(spacing: .none) {
                Text(showNames ? item.displayName : WidgetStatusStyle.title(resolved.status))
                    .textRole(.widgetRowTitle)
                    .lineLimit(1)
                Row(spacing: .xs) {
                    Text(item.timeText(dayParts: dayParts))
                    if item.takeWithFood {
                        Image(systemName: "fork.knife")
                    }
                }
                .textRole(.helper)
                .lineLimit(1)
                // "by 12:00 PM home · 6:00 PM here" or "Morning (Paris) · by 12:00 PM ·
                // Home: Night" away from the home zone.
                .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 4) // ds-allow: the least gap before the status mark

            Image(systemName: WidgetStatusStyle.symbol(resolved.status))
                .font(.footnote)
                .foregroundStyle(color)
                .widgetAccentable()
        }
    }
}

// MARK: - Avatar

struct AvatarView: View {
    let letter: String
    let hue: Double

    var body: some View {
        Text(letter)
            .textRole(.widgetRowTitle.weighted(.semibold))
            .foregroundStyle(.white) // ds-allow: on the per-medication hue, as the app's widget always drew it
            .frame(width: 28, height: 28) // ds-allow: the avatar, matched by the row's kind icon
            .background(Circle().fill(Color(hue: hue / 360, saturation: 0.55, brightness: 0.75))) // ds-allow: per-medication hue
    }
}

// MARK: - Empty state

struct AllDoneView: View {
    let compact: Bool

    var body: some View {
        Column(alignment: .center, spacing: compact ? .s : .m) {
            Image(systemName: "checkmark.circle.fill")
                .font(compact ? .title : .largeTitle)
                .foregroundStyle(.tone(.success))
                .widgetAccentable()
            Text("All done today")
                .textRole(compact ? .helper : .widgetName.colored(.secondary))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The widget's text roles (Dynamic Type styles, the theme's design).
extension TextRole {
    static let widgetName = TextRole("widgetName", style: .headline, usesDisplayDesign: true)
    static let widgetTime = TextRole("widgetTime", style: .subheadline, color: .secondary)
    static let widgetRowTitle = TextRole("widgetRowTitle", style: .subheadline, weight: .medium)
}
