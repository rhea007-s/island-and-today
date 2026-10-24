import SwiftUI
import WidgetKit

@main
struct TodayWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        CalendarWidget()
        // The Live Activities ship in the same extension. WidgetKit picks the
        // right one by attribute type.
        #if canImport(ActivityKit)
        FocusLiveActivity()
        MeetingLiveActivity()
        #endif
    }
}

struct TodayWidget: Widget {
    let kind = "TodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayWidgetEntryView(entry: entry)
                // Tapping anywhere that is not the toggle button opens the app.
                // With an empty day there is nothing to toggle, so the whole
                // widget becomes an "add a task" affordance instead — the app
                // opens straight into the composer.
                .widgetURL(AppGroup.url(
                    entry.snapshot.isEmpty ? AppGroup.Route.add : AppGroup.Route.today
                ))
        }
        .configurationDisplayName("Today")
        .description("What is left to do today, and what you have already finished.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .systemSmall
        ])
    }
}
