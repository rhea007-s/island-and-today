import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// The countdown to the next calendar event, in the Dynamic Island (iPhone 14
/// Pro and later) or on the Lock Screen and as a banner (every other iPhone).
/// The iPhone twin of the Mac island's meeting wings.
struct MeetingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var start: Date
        var end: Date
        var location: String?

        /// The system draws `Text(timerInterval:)` itself, so the clock costs
        /// no updates. The range must never be empty or the label traps.
        var untilStart: ClosedRange<Date> {
            let now = Date()
            return min(now, start)...max(start, now.addingTimeInterval(1))
        }

        var untilEnd: ClosedRange<Date> {
            start...max(end, start.addingTimeInterval(1))
        }
    }

    var eventID: String
    var rgb: [Double]
    var joinURL: URL?
}

#if canImport(ActivityKit)

/// One meeting countdown at a time, started from the app (ActivityKit refuses
/// requests from the background or from an extension).
enum MeetingSession {
    static var current: Activity<MeetingAttributes>? { Activity<MeetingAttributes>.activities.first }

    private static let autoKey = "meetingAutoStartedID"

    @discardableResult
    static func start(_ event: CalendarEvent) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, event.end > Date() else { return false }
        if current?.attributes.eventID == event.id { return true }
        endAll()
        let state = MeetingAttributes.ContentState(
            title: event.title, start: event.start, end: event.end, location: event.location
        )
        do {
            _ = try Activity.request(
                attributes: MeetingAttributes(eventID: event.id, rgb: event.rgb, joinURL: event.joinURL),
                // Going stale at the start time is what flips the island from
                // "starts in" to "now" without the app having to run.
                content: .init(state: state, staleDate: event.start > Date() ? event.start : event.end),
                pushType: nil
            )
            UserDefaults.standard.set(event.id, forKey: autoKey)
            return true
        } catch {
            return false
        }
    }

    /// Called whenever the app comes forward: starts the countdown for an
    /// event inside the window, once per event — if the user swipes it away,
    /// opening the app again must not bring it back.
    static func autoStart(_ events: [CalendarEvent], minutes: Int, now: Date = Date()) {
        cleanUp(now: now)
        guard minutes > 0, current == nil else { return }
        let window = TimeInterval(minutes * 60)
        guard let next = EventFeed.remainingToday(events, at: now)
            .first(where: { $0.isNow(now) || $0.start.timeIntervalSince(now) <= window }),
              UserDefaults.standard.string(forKey: autoKey) != next.id
        else { return }
        start(next)
    }

    /// The island cannot wake itself at the event's end, so a finished
    /// meeting is cleared the next time the app runs.
    static func cleanUp(now: Date = Date()) {
        for activity in Activity<MeetingAttributes>.activities where activity.content.state.end <= now {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    static func endAll() {
        for activity in Activity<MeetingAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}

#endif
