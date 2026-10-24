import EventKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One calendar event, flattened to plain values so it can cross into a widget
/// timeline or a Live Activity without dragging EventKit along.
struct CalendarEvent: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    /// The calendar's own colour, as sRGB components.
    var rgb: [Double]
    var location: String?
    var joinURL: URL?

    var color: Color {
        rgb.count == 3 ? Color(red: rgb[0], green: rgb[1], blue: rgb[2]) : .red
    }

    func isNow(_ date: Date) -> Bool { start <= date && date < end }
}

/// Read-only view of the user's calendars — iCloud, Google, Outlook, whatever
/// is added in Settings. The app and the widget both read through here; the
/// widget extension shares the app's calendar permission.
enum EventFeed {
    static let widgetKind = "UpNextWidget"

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Everything from the start of `date`'s day through the end of the next
    /// day, so "nothing left today" can still say what tomorrow starts with.
    static func events(around date: Date = Date(), store: EKEventStore = EKEventStore()) -> [CalendarEvent] {
        guard isAuthorized else { return [] }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 2, to: dayStart) else { return [] }
        let predicate = store.predicateForEvents(withStart: dayStart, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }
            .map(event)
    }

    // MARK: - Slicing, shared by every surface

    /// Timed events of `date`'s day that have not ended yet.
    static func remainingToday(_ events: [CalendarEvent], at date: Date) -> [CalendarEvent] {
        events.filter { !$0.isAllDay && $0.end > date && Calendar.current.isDate($0.start, inSameDayAs: date) }
    }

    static func allDayToday(_ events: [CalendarEvent], at date: Date) -> [CalendarEvent] {
        events.filter { $0.isAllDay && $0.start <= date && date < $0.end }
    }

    static func tomorrow(_ events: [CalendarEvent], at date: Date) -> [CalendarEvent] {
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: date) else { return [] }
        return events.filter { !$0.isAllDay && Calendar.current.isDate($0.start, inSameDayAs: next) }
    }

    // MARK: - Mapping

    private static func event(_ e: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: (e.eventIdentifier ?? UUID().uuidString) + "@\(Int(e.startDate.timeIntervalSince1970))",
            title: (e.title?.isEmpty == false ? e.title : nil) ?? "Untitled",
            start: e.startDate,
            end: e.endDate,
            isAllDay: e.isAllDay,
            rgb: components(e.calendar?.cgColor),
            // A bare meeting link is not a place; it becomes the Join button.
            location: e.location.flatMap { $0.isEmpty || $0.contains("://") ? nil : $0 },
            joinURL: joinLink(e)
        )
    }

    private static func components(_ color: CGColor?) -> [Double] {
        #if canImport(UIKit)
        guard let color else { return [1, 0.23, 0.19] }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(cgColor: color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b)]
        #else
        return [1, 0.23, 0.19]
        #endif
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

// MARK: - Deep links the widget and the Live Activity send

extension AppGroup {
    /// Opens the Calendar app at the event's day.
    static func calendarURL(at date: Date) -> URL? {
        URL(string: "\(urlScheme)://\(Route.calendar)?t=\(Int(date.timeIntervalSinceReferenceDate))")
    }

    /// Widgets can only open their own app, so a join link travels through it.
    static func joinURL(_ link: URL) -> URL? {
        var parts = URLComponents()
        parts.scheme = urlScheme
        parts.host = Route.join
        parts.queryItems = [URLQueryItem(name: "u", value: link.absoluteString)]
        return parts.url
    }
}
