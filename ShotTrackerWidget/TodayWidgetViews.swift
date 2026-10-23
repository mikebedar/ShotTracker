import SwiftUI
import WidgetKit

// MARK: - Entry view (family switch)

struct TodayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: TodayEntry

    var body: some View {
        let resolved = entry.snapshot.resolvedItems(at: entry.date)
        let showNames = entry.snapshot.showMedicationNames

        Group {
            switch family {
            case .systemSmall:
                SmallWidgetView(items: resolved, showNames: showNames)
            case .systemLarge:
                ListWidgetView(items: resolved, showNames: showNames, maxRows: 7)
            default:
                ListWidgetView(items: resolved, showNames: showNames, maxRows: 3)
            }
        }
        .widgetURL(WidgetShared.todayDeepLink)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Small: most-urgent dose

struct SmallWidgetView: View {
    let items: [ResolvedWidgetItem]
    let showNames: Bool

    var body: some View {
        if let top = items.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label {
                        Text(WidgetStatusStyle.title(top.status))
                            .font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: WidgetStatusStyle.symbol(top.status))
                    }
                    .foregroundStyle(WidgetStatusStyle.color(top.status))
                    Spacer()
                    if items.count > 1 {
                        Text("+\(items.count - 1)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if showNames {
                    Text(top.item.displayName)
                        .font(.headline)
                        .lineLimit(2)
                } else {
                    Image(systemName: top.item.kindSymbol)
                        .font(.title2)
                        .foregroundStyle(WidgetStatusStyle.color(top.status))
                }

                Text(top.item.timeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

    private var overdueCount: Int { items.filter { $0.status == .overdue }.count }

    var body: some View {
        if items.isEmpty {
            AllDoneView(compact: false)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Today's Doses")
                        .font(.headline)
                    Spacer()
                    if overdueCount > 0 {
                        Text("\(overdueCount) overdue")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.red))
                    }
                }

                ForEach(items.prefix(maxRows)) { resolved in
                    DoseRow(resolved: resolved, showNames: showNames)
                }

                if items.count > maxRows {
                    Text("+\(items.count - maxRows) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var item: WidgetDoseItem { resolved.item }
    private var color: Color { WidgetStatusStyle.color(resolved.status) }

    var body: some View {
        HStack(spacing: 10) {
            if showNames {
                AvatarView(letter: item.avatarLetter, hue: item.avatarHue)
            } else {
                Image(systemName: item.kindSymbol)
                    .font(.body)
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(color.opacity(0.15)))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(showNames ? item.displayName : WidgetStatusStyle.title(resolved.status))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.timeText)
                    if item.takeWithFood {
                        Image(systemName: "fork.knife")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: WidgetStatusStyle.symbol(resolved.status))
                .font(.footnote)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Avatar

struct AvatarView: View {
    let letter: String
    let hue: Double

    var body: some View {
        Text(letter)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color(hue: hue / 360, saturation: 0.55, brightness: 0.75)))
    }
}

// MARK: - Empty state

struct AllDoneView: View {
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(compact ? .title : .largeTitle)
                .foregroundStyle(.green)
            Text("All done today")
                .font(compact ? .caption : .headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
