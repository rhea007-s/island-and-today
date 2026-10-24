import Foundation

/// When a task is pinned to the clock: an appointment, or a block of time.
struct TaskSchedule: Codable, Hashable {
    var start: Date
    /// `nil` means a moment rather than a span.
    var end: Date?
    var isAllDay: Bool
    /// Free text — "Migros Ataşehir", "Zoom", an address. Not a coordinate:
    /// a place people recognise beats a place a map recognises.
    var location: String?

    init(start: Date, end: Date? = nil, isAllDay: Bool = false, location: String? = nil) {
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
    }

    /// Guards against an end that drifted before its start.
    var isValid: Bool {
        guard let end else { return true }
        return end >= start
    }
}

/// One thing to do (or one thing already done) on a given calendar day.
///
/// Subtasks are modelled by a parent pointer rather than nested arrays: the
/// store stays one flat list that is trivial to save, search and reorder, and
/// depth becomes free — a shopping task can hold a market, which holds items.
struct DayTask: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var isDone: Bool
    var createdAt: Date
    var completedAt: Date?
    /// "2026-09-27" — the day this task belongs to. Stored rather than derived
    /// so a task written just before midnight stays on the day you created it.
    var dayKey: String

    /// `nil` for a top-level task; otherwise the task this one sits under.
    var parentID: UUID?
    /// Set when the task is an appointment or a time block.
    var schedule: TaskSchedule?
    /// Identifier of the matching event in the user's calendar, once synced.
    var calendarEventID: String?
    /// Last local change. Two-way sync compares this against the calendar
    /// event's own modification date to decide which side wins.
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        isDone: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        dayKey: String? = nil,
        parentID: UUID? = nil,
        schedule: TaskSchedule? = nil,
        calendarEventID: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.dayKey = dayKey ?? DayKey.key(for: createdAt)
        self.parentID = parentID
        self.schedule = schedule
        self.calendarEventID = calendarEventID
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Hand-written so a `tasks.json` saved before these fields existed still
    /// decodes. Synthesised `Codable` would throw on every missing key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        title           = try c.decode(String.self, forKey: .title)
        isDone          = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        createdAt       = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        completedAt     = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        dayKey          = try c.decodeIfPresent(String.self, forKey: .dayKey) ?? DayKey.key(for: createdAt)
        parentID        = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        schedule        = try c.decodeIfPresent(TaskSchedule.self, forKey: .schedule)
        calendarEventID = try c.decodeIfPresent(String.self, forKey: .calendarEventID)
        updatedAt       = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// The fields the calendar mirrors. Sync skips a write when these already
    /// agree, which stops push and pull from ping-ponging forever.
    func matchesCalendarContent(title: String, start: Date, end: Date?, location: String?) -> Bool {
        guard let schedule else { return false }
        return self.title == title
            && Int(schedule.start.timeIntervalSince1970) == Int(start.timeIntervalSince1970)
            && Int((schedule.end ?? schedule.start).timeIntervalSince1970) == Int((end ?? start).timeIntervalSince1970)
            && (schedule.location ?? "") == (location ?? "")
    }

    var isSubtask: Bool { parentID != nil }
    var isScheduled: Bool { schedule != nil }
}

/// Stable, timezone-local string keys for calendar days.
enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date = Date()) -> String {
        // Re-read the time zone each call: the device can travel.
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    static func date(from key: String) -> Date? {
        formatter.timeZone = TimeZone.current
        return formatter.date(from: key)
    }

    /// "Today", "Yesterday", or a written-out date — for section headers.
    static func display(_ key: String) -> String {
        guard let date = date(from: key) else { return key }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// One day's worth of tasks, for the history screen.
struct DayGroup: Identifiable, Hashable {
    var dayKey: String
    var tasks: [DayTask]

    var id: String { dayKey }
    var title: String { DayKey.display(dayKey) }

    /// The tasks that represent actual work — containers excluded, so a day
    /// summary counts what was done rather than how deeply it was organised.
    var leafTasks: [DayTask] {
        let parents = Set(tasks.compactMap(\.parentID))
        return tasks.filter { !parents.contains($0.id) }
    }

    var doneCount: Int { leafTasks.filter(\.isDone).count }
    var totalCount: Int { leafTasks.count }
}

/// Everything the Lock Screen needs, precomputed. The widget never touches
/// the raw task array — it renders this and nothing else.
struct DaySnapshot {
    var dayKey: String
    var total: Int
    var doneCount: Int
    /// The one task worth putting on the Lock Screen right now.
    var headline: DayTask?

    var remaining: Int { max(0, total - doneCount) }
    var isEmpty: Bool { total == 0 }
    var allDone: Bool { total > 0 && doneCount == total }
    var progress: Double { total == 0 ? 0 : Double(doneCount) / Double(total) }

    static let empty = DaySnapshot(dayKey: DayKey.key(), total: 0, doneCount: 0, headline: nil)

    // Sample states for the widget previews: the three shapes the Lock Screen
    // has to handle well.
    static let preview = DaySnapshot(
        dayKey: DayKey.key(),
        total: 5,
        doneCount: 3,
        headline: DayTask(title: "Call the bank")
    )

    static let previewEmpty = DaySnapshot(
        dayKey: DayKey.key(),
        total: 0,
        doneCount: 0,
        headline: nil
    )

    static let previewAllDone = DaySnapshot(
        dayKey: DayKey.key(),
        total: 4,
        doneCount: 4,
        headline: DayTask(title: "Ship the widget", isDone: true, completedAt: Date())
    )

    static let previewLongTitle = DaySnapshot(
        dayKey: DayKey.key(),
        total: 7,
        doneCount: 2,
        headline: DayTask(title: "Book the dentist before the referral expires")
    )
}
