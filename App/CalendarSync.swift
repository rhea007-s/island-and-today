import Combine
import EventKit
import Foundation

/// Two-way bridge between the task list and the user's calendars.
///
/// EventKit is the only integration point that matters: Google, Outlook and
/// iCloud calendars all arrive through the same store once the account is added
/// in Settings. Integrating each provider separately would be work the system
/// already did.
@MainActor
final class CalendarSync: ObservableObject {

    enum Access: Equatable {
        case unknown, granted, denied, restricted
    }

    /// How far either side is searched. Beyond this, a calendar with years of
    /// history would make every sync slower for no visible benefit.
    static let pastWindow: TimeInterval = 14 * 24 * 60 * 60
    static let futureWindow: TimeInterval = 60 * 24 * 60 * 60

    @Published private(set) var access: Access = .unknown
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published var lastError: String?

    private let eventStore = EKEventStore()
    private let taskStore: TaskStore
    private var changeObserver: NSObjectProtocol?

    init(taskStore: TaskStore) {
        self.taskStore = taskStore
        refreshAccessState()
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    // MARK: - Permission

    func refreshAccessState() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:            access = .granted
        case .denied, .writeOnly:    access = .denied      // two-way needs reads
        case .restricted:            access = .restricted
        default:                     access = .unknown
        }
    }

    /// Asks once. A denial is final until the user changes it in Settings, so
    /// there is no point re-prompting — surface a message instead.
    func requestAccess() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            access = granted ? .granted : .denied
            if granted { startObservingCalendarChanges() }
        } catch {
            access = .denied
            lastError = error.localizedDescription
        }
    }

    /// The calendar can change while the app is open — another device, Siri,
    /// the Calendar app itself. Pull again when it does.
    private func startObservingCalendarChanges() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
    }

    // MARK: - Sync

    /// Deletions first, then local changes out, then remote changes in.
    /// Order matters: pushing before pulling means a task edited on both sides
    /// is compared against a calendar entry that is already up to date.
    func sync(around date: Date = Date()) async {
        guard access == .granted, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        drainDeletions()
        push()
        pull(around: date)
        lastSync = Date()
    }

    private func calendar() -> EKCalendar? {
        eventStore.defaultCalendarForNewEvents
            ?? eventStore.calendars(for: .event).first { $0.allowsContentModifications }
    }

    /// Remove events whose task was deleted while the calendar was out of reach.
    private func drainDeletions() {
        for eventID in TaskStore.pendingCalendarDeletions {
            if let event = eventStore.event(withIdentifier: eventID) {
                try? eventStore.remove(event, span: .thisEvent, commit: false)
            }
            TaskStore.clearCalendarDeletion(eventID)
        }
        try? eventStore.commit()
    }

    // MARK: Local → calendar

    private func push() {
        guard let calendar = calendar() else {
            lastError = "No writable calendar found."
            return
        }

        for task in taskStore.tasks where task.schedule != nil {
            guard let schedule = task.schedule, schedule.isValid else { continue }

            let event: EKEvent
            if let eventID = task.calendarEventID, let existing = eventStore.event(withIdentifier: eventID) {
                // Both sides changed? Newer wins. The calendar's own modification
                // date is the only trustworthy clock for the remote side.
                let remoteDate = existing.lastModifiedDate ?? .distantPast
                if remoteDate > task.updatedAt { continue }   // pull handles it
                if task.matchesCalendarContent(
                    title: existing.title ?? "",
                    start: existing.startDate,
                    end: existing.endDate,
                    location: existing.location
                ) { continue }                                // already agrees
                event = existing
            } else if task.calendarEventID == nil {
                event = EKEvent(eventStore: eventStore)
                event.calendar = calendar
            } else {
                // Linked to an event that no longer exists: recreate it.
                event = EKEvent(eventStore: eventStore)
                event.calendar = calendar
            }

            event.title = task.title
            event.startDate = schedule.start
            event.endDate = schedule.end ?? schedule.start.addingTimeInterval(3600)
            event.isAllDay = schedule.isAllDay
            event.location = schedule.location

            do {
                try eventStore.save(event, span: .thisEvent, commit: false)
                if task.calendarEventID != event.eventIdentifier {
                    taskStore.linkCalendarEvent(id: task.id, eventID: event.eventIdentifier)
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        try? eventStore.commit()
    }

    // MARK: Calendar → local

    private func pull(around date: Date) {
        let start = date.addingTimeInterval(-Self.pastWindow)
        let end = date.addingTimeInterval(Self.futureWindow)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)

        let linked = Dictionary(
            uniqueKeysWithValues: taskStore.tasks
                .compactMap { task in task.calendarEventID.map { ($0, task) } }
        )

        for event in eventStore.events(matching: predicate) {
            guard let eventID = event.eventIdentifier else { continue }
            let schedule = TaskSchedule(
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location
            )

            if let task = linked[eventID] {
                let remoteDate = event.lastModifiedDate ?? .distantPast
                guard remoteDate > task.updatedAt else { continue }
                guard !task.matchesCalendarContent(
                    title: event.title ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    location: event.location
                ) else { continue }
                taskStore.applyFromCalendar(
                    id: task.id,
                    title: event.title ?? task.title,
                    schedule: schedule,
                    at: remoteDate
                )
            } else {
                // An appointment the app has never seen: adopt it.
                guard let title = event.title, !title.isEmpty else { continue }
                if let newID = taskStore.add(title, on: event.startDate, schedule: schedule) {
                    taskStore.linkCalendarEvent(id: newID, eventID: eventID)
                }
            }
        }
    }
}
