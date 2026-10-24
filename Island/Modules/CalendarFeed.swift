import SwiftUI
import Observation
import EventKit

/// Today's calendar, read from every calendar the Mac knows (iCloud, Google,
/// Exchange — whatever is in the Calendar app).
///
/// Nothing polls: the list is re-read when EventKit says the store changed,
/// and one timer is armed for the next moment the island's answer changes —
/// a reminder window opening, an event starting or ending.
@MainActor
@Observable
final class CalendarFeed {
    struct Event: Identifiable, Equatable {
        let id: String
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var color: Color
        var location: String?
        var joinURL: URL?

        func isNow(_ date: Date) -> Bool { start <= date && date < end }
    }

    enum Access { case unknown, granted, denied }

    private(set) var access: Access = .unknown
    private(set) var today: [Event] = []
    /// Bumped when a reminder window opens or an event starts or ends, so
    /// anything that asked `soon()` is asked again.
    private(set) var tick = 0

    weak var settings: IslandSettings?

    private let store = EKEventStore()
    private var timer: Timer?

    func start() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
            begin()
        case .denied, .restricted, .writeOnly:
            access = .denied
        default:
            access = .unknown
        }
    }

    /// Asked from a button, not at launch: the permission prompt should come
    /// when the user has just said they want their calendar here.
    func requestAccess() {
        Task { @MainActor in
            let ok = (try? await store.requestFullAccessToEvents()) ?? false
            access = ok ? .granted : .denied
            if ok { begin() }
        }
    }

    private func begin() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func reload() {
        guard access == .granted else { return }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date())
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: nil)
        let fresh = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }
            .map(Self.event)
        if fresh != today { withAnimation(.spring(response: 0.35, dampingFraction: 1)) { today = fresh } }
        arm()
    }

    // MARK: - What the island shows

    var remindMinutes: Int { settings?.remindMinutes ?? 10 }

    /// Timed events that have not ended yet.
    func upcoming(after date: Date = .now) -> [Event] {
        _ = tick
        return today.filter { !$0.isAllDay && $0.end > date }
    }

    /// The event worth a place in the notch: happening now, or starting
    /// within the reminder window.
    func soon(at date: Date = .now) -> Event? {
        guard settings?.showCalendar ?? true else { return nil }
        return upcoming(after: date).first { e in
            e.isNow(date) || e.start.timeIntervalSince(date) <= TimeInterval(remindMinutes * 60)
        }
    }

    /// One timer, for the next instant `soon()` can change its answer.
    private func arm() {
        timer?.invalidate()
        let now = Date()
        let lead = TimeInterval(remindMinutes * 60)
        let moments = today.filter { !$0.isAllDay }
            .flatMap { [$0.start.addingTimeInterval(-lead), $0.start, $0.end] }
            .filter { $0 > now }
        guard let next = moments.min() else { return }
        let t = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(IslandMotion.spring(opening: true, reduceMotion: false)) { self.tick += 1 }
                self.arm()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func event(_ e: EKEvent) -> Event {
        Event(
            id: (e.eventIdentifier ?? UUID().uuidString) + "\(e.startDate.timeIntervalSince1970)",
            title: (e.title?.isEmpty == false ? e.title : nil) ?? "Untitled",
            start: e.startDate,
            end: e.endDate,
            isAllDay: e.isAllDay,
            color: Color(nsColor: e.calendar?.color ?? .systemBlue),
            location: e.location?.isEmpty == false ? e.location : nil,
            joinURL: joinLink(e)
        )
    }

    /// A video-call link if the event has one: its URL field, else the first
    /// Zoom / Meet / Teams / Webex link in the location or notes.
    private static func joinLink(_ e: EKEvent) -> URL? {
        if let url = e.url, url.scheme?.hasPrefix("http") == true { return url }
        let text = [e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "facetime.apple.com"]
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url)
            .first { url in hosts.contains { url.host?.contains($0) == true } }
    }
}

// MARK: - Views

/// "Schedule" block at the top of the Today tab.
struct ScheduleSection: View {
    let model: IslandModel
    private var feed: CalendarFeed { model.calendar }

    var body: some View {
        if model.settings.showCalendar {
            switch feed.access {
            case .granted:
                let events = feed.upcoming()
                let allDay = feed.today.filter(\.isAllDay)
                if !events.isEmpty || !allDay.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(allDay) { AllDayRow(event: $0) }
                        ForEach(events.prefix(3)) { EventRow(event: $0) }
                        if events.count > 3 {
                            Text("+\(events.count - 3) more today")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.leading, 14)
                        }
                    }
                }
            case .unknown:
                Button {
                    feed.requestAccess()
                } label: {
                    Label("Show today's calendar here", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(ChipStyle())
            case .denied:
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                } label: {
                    Label("Calendar access is off — open Settings", systemImage: "calendar.badge.exclamationmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct EventRow: View {
    let event: CalendarFeed.Event

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = event.isNow(context.date)
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(event.start, format: .dateTime.hour().minute()) – \(event.end, format: .dateTime.hour().minute())")
                        if let place = event.location, event.joinURL == nil {
                            Text("· \(place)").lineLimit(1)
                        }
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 6)
                if now {
                    Text("NOW")
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(event.color.opacity(0.85)))
                } else {
                    Text(event.start, style: .relative)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                }
                if let url = event.joinURL {
                    Button("Join") { NSWorkspace.shared.open(url) }
                        .buttonStyle(ChipStyle())
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(now ? event.color.opacity(0.14) : .clear))
        }
    }
}

private struct AllDayRow: View {
    let event: CalendarFeed.Event

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(event.color).frame(width: 6, height: 6)
            Text(event.title).lineLimit(1)
            Text("all day").foregroundStyle(.white.opacity(0.4))
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.leading, 6)
    }
}

/// Compact wing content while an event is close: a colored calendar glyph on
/// the left, the countdown (or "now") on the right.
struct MeetingWing: View {
    let event: CalendarFeed.Event
    var leading: Bool

    var body: some View {
        if leading {
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(event.color)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Group {
                    if event.isNow(context.date) {
                        Text("now")
                    } else {
                        Text(timerInterval: context.date...max(event.start, context.date.addingTimeInterval(1)), countsDown: true, showsHours: false)
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(event.color)
            }
        }
    }
}
