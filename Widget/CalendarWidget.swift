import SwiftUI
import WidgetKit

// MARK: - Timeline

struct CalendarEntry: TimelineEntry {
    let date: Date
    let events: [CalendarEvent]
    let authorized: Bool

    var allDay: [CalendarEvent] { EventFeed.allDayToday(events, at: date) }
    var remaining: [CalendarEvent] { EventFeed.remainingToday(events, at: date) }
    var tomorrow: [CalendarEvent] { EventFeed.tomorrow(events, at: date) }
    var next: CalendarEvent? { remaining.first }
}

struct CalendarProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalendarEntry {
        CalendarEntry(date: .now, events: CalendarEvent.previewDay, authorized: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (CalendarEntry) -> Void) {
        if context.isPreview || !EventFeed.isAuthorized {
            completion(placeholder(in: context))
        } else {
            completion(CalendarEntry(date: .now, events: EventFeed.events(), authorized: true))
        }
    }

    /// One entry for now, then one at every moment the picture changes — an
    /// hour before an event (the countdown appears), its start (NOW) and its
    /// end (it leaves the list). Between those the system's own timer text
    /// keeps the clock running, so no extra reloads are spent on it.
    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarEntry>) -> Void) {
        let now = Date()
        guard EventFeed.isAuthorized else {
            completion(Timeline(entries: [CalendarEntry(date: now, events: [], authorized: false)],
                                policy: .after(now.addingTimeInterval(60 * 60))))
            return
        }
        let events = EventFeed.events(around: now)
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60 + 5)
        let moments = Set(events.filter { !$0.isAllDay }
            .flatMap { [$0.start.addingTimeInterval(-3600), $0.start, $0.end] } + [midnight])
            .filter { $0 > now && $0 <= midnight }
            .sorted()
            .prefix(40)
        let entries = [CalendarEntry(date: now, events: events, authorized: true)]
            + moments.map { CalendarEntry(date: $0, events: events, authorized: true) }
        // Calendars also change from other devices; WidgetKit has no signal
        // for that, so look again every half hour.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

// MARK: - Widget

struct CalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: EventFeed.widgetKind, provider: CalendarProvider()) { entry in
            CalendarWidgetView(entry: entry)
                .widgetURL(entry.authorized
                           ? AppGroup.calendarURL(at: entry.next?.start ?? entry.date)
                           : AppGroup.url(AppGroup.Route.today))
        }
        .configurationDisplayName("Up Next")
        .description("Today's calendar, with a countdown to your next event.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline, .accessoryCircular,
        ])
    }
}

struct CalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CalendarEntry

    var body: some View {
        Group {
            if !entry.authorized {
                NeedsAccessView(family: family)
            } else {
                switch family {
                case .accessoryRectangular: UpNextRectangular(entry: entry)
                case .accessoryInline: UpNextInline(entry: entry)
                case .accessoryCircular: UpNextCircular(entry: entry)
                case .systemMedium: UpNextMedium(entry: entry)
                case .systemLarge: UpNextLarge(entry: entry)
                default: UpNextSmall(entry: entry)
                }
            }
        }
        .containerBackground(for: .widget) {
            if family == .systemSmall || family == .systemMedium || family == .systemLarge {
                Color(.systemBackground)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Pieces every size uses

/// "SAT 18" — the date block Calendar itself uses, red weekday over the day.
private struct DateBlock: View {
    let date: Date
    var big = false

    var body: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(date, format: .dateTime.weekday(.abbreviated))
                .font(.system(size: big ? 13 : 11, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.red)
            Text(date, format: .dateTime.day())
                .font(.system(size: big ? 40 : 28, weight: .regular, design: .rounded))
                .monospacedDigit()
        }
    }
}

/// "in 12:04" inside the last hour, "NOW" while it runs, the start time
/// otherwise. The timer text is advanced by the system every second.
private struct WhenLabel: View {
    let event: CalendarEvent
    let at: Date
    var alignment: Alignment = .trailing

    var body: some View {
        if event.isNow(at) {
            Text("NOW")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(event.color))
        } else if event.start.timeIntervalSince(at) <= 3600 {
            Text(timerInterval: at...max(event.start, at.addingTimeInterval(1)), countsDown: true, showsHours: false)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(event.color)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                .frame(maxWidth: 48, alignment: alignment)
        } else {
            Text(event.start, format: .dateTime.hour().minute())
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct EventLine: View {
    let event: CalendarEvent
    let at: Date
    var showsJoin = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(event.start, format: .dateTime.hour().minute()) – \(event.end, format: .dateTime.hour().minute())")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if showsJoin, let url = event.joinURL, let link = AppGroup.joinURL(url) {
                Link(destination: link) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 22)
                        .background(Capsule().fill(.green))
                }
            }
            WhenLabel(event: event, at: at)
        }
        .frame(height: 30)
    }
}

private struct AllDayChip: View {
    let event: CalendarEvent

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(event.color).frame(width: 6, height: 6)
            Text(event.title).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(event.color.opacity(0.15)))
    }
}

/// When today is done: say so, and say how tomorrow starts.
private struct DayDoneView: View {
    let entry: CalendarEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No more events today")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            if let first = entry.tomorrow.first {
                Text("Tomorrow \(first.start, format: .dateTime.hour().minute()) · \(first.title)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Home Screen

struct UpNextSmall: View {
    let entry: CalendarEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                DateBlock(date: entry.date)
                Spacer()
                if entry.remaining.count > 1 {
                    Text("+\(entry.remaining.count - 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let next = entry.next {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(next.color).frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                        Text(next.start, format: .dateTime.hour().minute())
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        WhenLabel(event: next, at: entry.date, alignment: .leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                if let first = entry.allDay.first { AllDayChip(event: first) }
                DayDoneView(entry: entry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct UpNextMedium: View {
    let entry: CalendarEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                DateBlock(date: entry.date, big: true)
                Spacer(minLength: 0)
                Text(countLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                if let first = entry.allDay.first { AllDayChip(event: first) }
                if entry.remaining.isEmpty {
                    Spacer(minLength: 0)
                    DayDoneView(entry: entry)
                    Spacer(minLength: 0)
                } else {
                    ForEach(entry.remaining.prefix(entry.allDay.isEmpty ? 3 : 2)) { event in
                        EventLine(event: event, at: entry.date, showsJoin: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var countLine: String {
        let n = entry.remaining.count
        return n == 0 ? "All clear" : n == 1 ? "1 event left" : "\(n) events left"
    }
}

struct UpNextLarge: View {
    let entry: CalendarEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                DateBlock(date: entry.date, big: true)
                Spacer()
                Text(entry.date, format: .dateTime.month(.wide))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if !entry.allDay.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.allDay.prefix(2)) { AllDayChip(event: $0) }
                }
            }
            Divider()
            if entry.remaining.isEmpty {
                DayDoneView(entry: entry)
            } else {
                ForEach(entry.remaining.prefix(6)) { event in
                    EventLine(event: event, at: entry.date, showsJoin: true)
                }
            }
            let room = 6 - entry.remaining.count
            if room >= 2, !entry.tomorrow.isEmpty, !entry.remaining.isEmpty {
                Text("TOMORROW")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(entry.tomorrow.prefix(room - 1)) { event in
                    EventLine(event: event, at: entry.date)
                        .opacity(0.7)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Lock Screen

struct UpNextRectangular: View {
    let entry: CalendarEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let next = entry.next {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                    if next.isNow(entry.date) {
                        Text("Now · until \(next.end, format: .dateTime.hour().minute())")
                    } else if next.start.timeIntervalSince(entry.date) <= 3600 {
                        Text("in ") + Text(timerInterval: entry.date...max(next.start, entry.date.addingTimeInterval(1)),
                                           countsDown: true, showsHours: false)
                    } else {
                        Text(next.start, format: .dateTime.hour().minute())
                    }
                }
                .font(.caption2.weight(.semibold))
                .widgetAccentable()
                Text(next.title)
                    .font(.headline)
                    .lineLimit(2)
                if let after = entry.remaining.dropFirst().first {
                    Text("then \(after.start, format: .dateTime.hour().minute()) \(after.title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Label("Calendar", systemImage: "calendar")
                    .font(.caption2.weight(.semibold))
                    .widgetAccentable()
                Text("No more events")
                    .font(.headline)
                if let first = entry.tomorrow.first {
                    Text("Tomorrow \(first.start, format: .dateTime.hour().minute())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct UpNextInline: View {
    let entry: CalendarEntry

    var body: some View {
        if let next = entry.next {
            if next.isNow(entry.date) {
                Label("\(next.title) · now", systemImage: "calendar")
            } else {
                Label {
                    Text("\(next.start, format: .dateTime.hour().minute()) \(next.title)")
                } icon: {
                    Image(systemName: "calendar")
                }
            }
        } else {
            Label("No more events", systemImage: "calendar")
        }
    }
}

struct UpNextCircular: View {
    let entry: CalendarEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                if let next = entry.next {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                    if next.isNow(entry.date) {
                        Text("NOW").font(.system(size: 14, weight: .heavy))
                    } else {
                        Text(next.start, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .minimumScaleFactor(0.6)
                    }
                } else {
                    Text(entry.date, format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: 10, weight: .bold))
                        .textCase(.uppercase)
                    Text(entry.date, format: .dateTime.day())
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                }
            }
            .widgetAccentable()
        }
    }
}

// MARK: - Before the app has been allowed to read the calendar

private struct NeedsAccessView: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("Open Today to show calendar", systemImage: "calendar")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "calendar.badge.plus").font(.title3)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label("Up Next", systemImage: "calendar").font(.caption2.weight(.semibold))
                Text("Open Today and allow Calendar").font(.headline).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "calendar.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.red)
                Spacer(minLength: 0)
                Text("Show your calendar")
                    .font(.system(size: 14, weight: .semibold))
                Text("Open Today and tap \u{201C}Show my calendar\u{201D}.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Previews

extension CalendarEvent {
    static var previewDay: [CalendarEvent] {
        let now = Date()
        func at(_ minutes: Double, _ length: Double, _ title: String, _ rgb: [Double], join: Bool = false) -> CalendarEvent {
            CalendarEvent(id: title, title: title, start: now.addingTimeInterval(minutes * 60),
                          end: now.addingTimeInterval((minutes + length) * 60), isAllDay: false, rgb: rgb,
                          location: nil, joinURL: join ? URL(string: "https://meet.google.com/abc") : nil)
        }
        let dayStart = Calendar.current.startOfDay(for: now)
        return [
            CalendarEvent(id: "bday", title: "Ece's birthday", start: dayStart, end: dayStart.addingTimeInterval(86400),
                          isAllDay: true, rgb: [1, 0.58, 0], location: nil, joinURL: nil),
            at(12, 30, "Team standup", [0.2, 0.5, 1], join: true),
            at(90, 60, "Lunch with Deniz", [0.2, 0.78, 0.35]),
            at(240, 45, "Dentist", [1, 0.23, 0.19]),
        ]
    }
}

#Preview("Small", as: .systemSmall) {
    CalendarWidget()
} timeline: {
    CalendarEntry(date: .now, events: CalendarEvent.previewDay, authorized: true)
    CalendarEntry(date: .now, events: [], authorized: true)
    CalendarEntry(date: .now, events: [], authorized: false)
}

#Preview("Medium", as: .systemMedium) {
    CalendarWidget()
} timeline: {
    CalendarEntry(date: .now, events: CalendarEvent.previewDay, authorized: true)
}

#Preview("Large", as: .systemLarge) {
    CalendarWidget()
} timeline: {
    CalendarEntry(date: .now, events: CalendarEvent.previewDay, authorized: true)
}

#Preview("Lock Screen", as: .accessoryRectangular) {
    CalendarWidget()
} timeline: {
    CalendarEntry(date: .now, events: CalendarEvent.previewDay, authorized: true)
}
