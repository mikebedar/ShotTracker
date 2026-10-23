import WidgetKit
import SwiftUI

struct TodayWidget: Widget {
    let kind = "ShotTrackerTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayWidgetProvider()) { entry in
            TodayWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Today's Doses")
        .description("See your overdue and upcoming medication doses for today.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
