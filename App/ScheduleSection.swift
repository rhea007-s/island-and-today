import Combine
import EventKit
import SwiftUI
import UIKit
import WidgetKit

/// Today's calendar inside the app, and the switch for the Dynamic Island
/// countdown. Read-only: nothing here writes to a calendar.
@MainActor
final class ScheduleModel: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [CalendarEvent] = []

    /// Minutes before an event the island countdown starts by itself when the
    /// app is opened; 0 turns it off.
    @Published var islandMinutes: Int {
        didSet { UserDefaults.standard.set(islandMinutes, forKey: "islandMinutes") }
    }

    private let store = EKEventStore()
    private var observers: [NSObjectProtocol] = []

    init() {
        UserDefaults.standard.register(defaults: ["islandMinutes": 30])
        islandMinutes = UserDefaults.standard.integer(forKey: "islandMinutes")
        refreshAccess()
        if access == .granted { observe() }
    }

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .denied, .restricted, .writeOnly: access = .denied
        default: access = .unknown
        }
    }

    /// Asked from a button: the prompt should come right after the user says
    /// they want their calendar here.
    func requestAccess() {
        Task {
            let ok = (try? await store.requestFullAccessToEvents()) ?? false
            access = ok ? .granted : .denied
            if ok {
                observe()
                reload()
            }
        }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        })
    }

    /// Re-reads the day, tells the widget, and starts the island countdown if
    /// an event is close. Called on launch, on every return to the app, and
    /// whenever the calendar changes.
    func reload() {
        refreshAccess()
        guard access == .granted else { return }
        let fresh = EventFeed.events(store: store)
        if fresh != events {
            withAnimation(.spring(response: 0.35, dampingFraction: 1)) { events = fresh }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: EventFeed.widgetKind)
        MeetingSession.autoStart(fresh, minutes: islandMinutes)
    }
}

struct ScheduleSection: View {
    @ObservedObject var model: ScheduleModel

    var body: some View {
        switch model.access {
        case .unknown:
            Section {
                Button {
                    model.requestAccess()
                } label: {
                    Label("Show my calendar", systemImage: "calendar.badge.plus")
                }
            } footer: {
                Text("Your events show here, in the Up Next widget and as a countdown in the Dynamic Island.")
            }
        case .denied:
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Calendar access is off — open Settings", systemImage: "calendar.badge.exclamationmark")
                }
                .foregroundStyle(.secondary)
            }
        case .granted:
            granted
        }
    }

    private var granted: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let allDay = EventFeed.allDayToday(model.events, at: now)
            let remaining = EventFeed.remainingToday(model.events, at: now)
            Section {
                ForEach(allDay) { event in
                    HStack(spacing: 8) {
                        Circle().fill(event.color).frame(width: 8, height: 8)
                        Text(event.title).font(.subheadline)
                        Spacer()
                        Text("all day").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(remaining) { event in
                    EventRow(event: event, now: now, isInIsland: MeetingSession.current?.attributes.eventID == event.id)
                        .swipeActions(edge: .leading) {
                            Button { MeetingSession.start(event) } label: {
                                Label("Island", systemImage: "capsule.fill")
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button("Count down in Dynamic Island", systemImage: "capsule.fill") {
                                MeetingSession.start(event)
                            }
                            Button("Open in Calendar", systemImage: "calendar") {
                                openCalendar(at: event.start)
                            }
                            if let url = event.joinURL {
                                Button("Join call", systemImage: "video.fill") { UIApplication.shared.open(url) }
                            }
                        }
                }
                if remaining.isEmpty && allDay.isEmpty {
                    Text("No more events today")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Calendar")
                    Spacer()
                    islandMenu
                }
            }
        }
    }

    private var islandMenu: some View {
        Menu {
            Picker("Island countdown", selection: $model.islandMinutes) {
                Text("Off").tag(0)
                ForEach([10, 15, 30, 60], id: \.self) { Text("\($0) min before").tag($0) }
            }
        } label: {
            Label(model.islandMinutes == 0 ? "Island off" : "Island \(model.islandMinutes) min",
                  systemImage: "capsule.fill")
                .font(.caption.weight(.semibold))
                .textCase(nil)
        }
    }

    private func openCalendar(at date: Date) {
        if let url = URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))") {
            UIApplication.shared.open(url)
        }
    }
}

private struct EventRow: View {
    let event: CalendarEvent
    let now: Date
    let isInIsland: Bool

    /// A meeting link pasted into the location is already the Join button.
    private var place: String? {
        guard let location = event.location, !location.contains("://") else { return nil }
        return location
    }

    /// "in 6 min", "in 1 h 12 min" — short enough for an iPhone SE row. The
    /// section re-renders every minute, so this stays current.
    static func until(_ start: Date, from now: Date) -> String {
        let minutes = max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "in \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.color)
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(event.start, format: .dateTime.hour().minute()) – \(event.end, format: .dateTime.hour().minute())\(place.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if isInIsland {
                Image(systemName: "capsule.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if event.isNow(now) {
                Text("NOW")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(event.color))
            } else {
                Text(Self.until(event.start, from: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let url = event.joinURL {
                Button("Join") { UIApplication.shared.open(url) }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
            }
        }
    }
}
