import WidgetKit

struct DayEntry: TimelineEntry {
    let date: Date
    let snapshot: DaySnapshot
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> DayEntry {
        DayEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (DayEntry) -> Void) {
        let snapshot = context.isPreview ? DaySnapshot.preview : TaskStore.snapshot()
        completion(DayEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DayEntry>) -> Void) {
        let now = Date()
        let entry = DayEntry(date: now, snapshot: TaskStore.snapshot(for: now))

        // Content only changes when the user acts (the app and the intent both
        // call reloadAllTimelines), plus once at midnight when "today" moves on.
        let reloadAt = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 10),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(60 * 60)

        completion(Timeline(entries: [entry], policy: .after(reloadAt)))
    }
}
