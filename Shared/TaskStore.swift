import Foundation
import WidgetKit

/// Owns the task list. Used by both the app (as an `ObservableObject`) and the
/// widget extension (via the `static` read/mutate helpers).
///
/// Every mutation is *disk-authoritative*: it re-reads the JSON file, applies
/// the change, and writes it back. Two processes touch this data — the app and
/// the widget's interactive intent — so an in-memory array is never the source
/// of truth.
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published private(set) var tasks: [DayTask] = []

    init() {
        tasks = Self.read()
    }

    // MARK: - Reading

    static func read() -> [DayTask] {
        guard let data = try? Data(contentsOf: AppGroup.storeURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DayTask].self, from: data)) ?? []
    }

    private static func write(_ tasks: [DayTask]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(tasks) else { return }
        // .atomic: a crash mid-write leaves the old file intact rather than a
        // half-written one the widget would fail to decode.
        try? data.write(to: AppGroup.storeURL, options: .atomic)
    }

    /// Re-read from disk, mutate, write back, then refresh both the UI and the
    /// Lock Screen. The single funnel for every change.
    private func mutate(_ change: (inout [DayTask]) -> Void) {
        var current = Self.read()
        change(&current)
        Self.write(current)
        tasks = current
        WidgetCenter.shared.reloadAllTimelines()
        CloudSync.localChanged()
    }

    /// Merges what the other device changed. Newest `updatedAt` wins on both
    /// sides; a tombstone only removes a task that was not edited after it.
    /// Deliberately not through `mutate`: echoing a pull back as a local
    /// change would trigger another sync for nothing.
    func applyRemote(upserts: [DayTask], deletions: [UUID: Date]) {
        var current = Self.read()
        for remote in upserts {
            if let i = current.firstIndex(where: { $0.id == remote.id }) {
                if remote.updatedAt > current[i].updatedAt { current[i] = remote }
            } else {
                current.append(remote)
            }
        }
        current.removeAll { task in
            guard let deletedAt = deletions[task.id] else { return false }
            return task.updatedAt <= deletedAt
        }
        Self.write(current)
        tasks = current
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Same funnel, without the `@Published` hop — for use inside the widget
    /// extension, where there is no view model to update.
    static func mutateFromExtension(_ change: (inout [DayTask]) -> Void) {
        var current = read()
        change(&current)
        write(current)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Mutations

    @discardableResult
    func add(
        _ title: String,
        on date: Date = Date(),
        parentID: UUID? = nil,
        schedule: TaskSchedule? = nil
    ) -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A subtask belongs to the same day as its parent, whatever today is.
        let day = parentID.flatMap { id in Self.read().first { $0.id == id }?.dayKey }
            ?? DayKey.key(for: date)
        let task = DayTask(
            title: trimmed,
            createdAt: date,
            dayKey: day,
            parentID: parentID,
            schedule: schedule
        )
        mutate { $0.append(task) }
        return task.id
    }

    func schedule(id: UUID, to schedule: TaskSchedule?) {
        mutate { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i].schedule = schedule
            if let start = schedule?.start { tasks[i].dayKey = DayKey.key(for: start) }
            tasks[i].updatedAt = Date()
        }
    }

    func linkCalendarEvent(id: UUID, eventID: String?) {
        mutate { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i].calendarEventID = eventID
        }
    }

    func toggle(id: UUID) {
        mutate { Self.applyToggle(id: id, to: &$0) }
    }

    /// Deletes a task and everything beneath it. Without the cascade the
    /// children survive as orphans: still in the file, invisible in every view.
    func delete(id: UUID) {
        mutate { tasks in
            let doomed = Self.subtreeIDs(of: id, in: tasks)
            // Remember any calendar events so the next sync can remove them too.
            for task in tasks where doomed.contains(task.id) {
                if let eventID = task.calendarEventID { Self.enqueueCalendarDeletion(eventID) }
            }
            tasks.removeAll { doomed.contains($0.id) }
            CloudSync.enqueueDeletion(doomed)
        }
    }

    /// A task plus every descendant, found breadth-first.
    static func subtreeIDs(of id: UUID, in tasks: [DayTask]) -> Set<UUID> {
        var found: Set<UUID> = [id]
        var frontier: [UUID] = [id]
        while let current = frontier.popLast() {
            for task in tasks where task.parentID == current && !found.contains(task.id) {
                found.insert(task.id)
                frontier.append(task.id)
            }
        }
        return found
    }

    func rename(id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i].title = trimmed
            tasks[i].updatedAt = Date()
        }
    }

    /// Move unfinished tasks from earlier days onto today, so yesterday's
    /// leftovers do not silently disappear from the Lock Screen.
    func rolloverUnfinished(to date: Date = Date()) {
        let today = DayKey.key(for: date)
        mutate { tasks in
            for i in tasks.indices where !tasks[i].isDone && tasks[i].dayKey < today {
                tasks[i].dayKey = today
            }
        }
    }

    /// Shared toggle logic so the app and the widget intent behave identically.
    static func applyToggle(id: UUID, to tasks: inout [DayTask]) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isDone.toggle()
        tasks[i].completedAt = tasks[i].isDone ? Date() : nil
        tasks[i].updatedAt = Date()
    }

    // MARK: - Calendar bookkeeping

    /// Events whose task was deleted locally and which the calendar has not
    /// caught up with yet. Kept in the App Group so a sync from any launch
    /// can drain it — otherwise deleting a task would orphan its event.
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }
    private static let pendingKey = "pendingCalendarDeletions"

    static var pendingCalendarDeletions: [String] {
        get { defaults.stringArray(forKey: pendingKey) ?? [] }
        set { defaults.set(newValue, forKey: pendingKey) }
    }

    static func enqueueCalendarDeletion(_ eventID: String) {
        var queue = pendingCalendarDeletions
        guard !queue.contains(eventID) else { return }
        queue.append(eventID)
        pendingCalendarDeletions = queue
    }

    static func clearCalendarDeletion(_ eventID: String) {
        pendingCalendarDeletions = pendingCalendarDeletions.filter { $0 != eventID }
    }

    /// Applies a change the calendar made to a task we already track.
    func applyFromCalendar(id: UUID, title: String, schedule: TaskSchedule, at date: Date) {
        mutate { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            tasks[i].title = title
            tasks[i].schedule = schedule
            tasks[i].dayKey = DayKey.key(for: schedule.start)
            tasks[i].updatedAt = date
        }
    }

    // MARK: - Queries

    func tasks(on date: Date = Date()) -> [DayTask] {
        Self.tasks(Self.read(), on: date)
    }

    static func tasks(_ all: [DayTask], on date: Date = Date()) -> [DayTask] {
        let key = DayKey.key(for: date)
        return all.filter { $0.dayKey == key }
                  .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - The tree

    /// Top-level tasks for a day, oldest first. Subtasks are reached through
    /// `children(of:)` rather than being nested here.
    static func roots(_ all: [DayTask], on date: Date = Date()) -> [DayTask] {
        tasks(all, on: date).filter { $0.parentID == nil }
    }

    func roots(on date: Date = Date()) -> [DayTask] { Self.roots(tasks, on: date) }

    static func children(of id: UUID, in all: [DayTask]) -> [DayTask] {
        all.filter { $0.parentID == id }.sorted { $0.createdAt < $1.createdAt }
    }

    func children(of id: UUID) -> [DayTask] { Self.children(of: id, in: tasks) }

    /// How far a branch has got: done and total across every descendant.
    /// A parent with children reports their progress, not its own checkbox.
    static func progress(of id: UUID, in all: [DayTask]) -> (done: Int, total: Int) {
        let descendants = subtreeIDs(of: id, in: all).subtracting([id])
        guard !descendants.isEmpty else {
            let isDone = all.first { $0.id == id }?.isDone ?? false
            return (isDone ? 1 : 0, 1)
        }
        // Only leaves count. An intermediate node ("Migros") is a container,
        // not a piece of work — counting it inflates the total and makes a
        // branch look less finished than it is.
        let hasChildren = Set(all.compactMap(\.parentID))
        let leaves = all.filter { descendants.contains($0.id) && !hasChildren.contains($0.id) }
        return (leaves.filter(\.isDone).count, leaves.count)
    }

    func progress(of id: UUID) -> (done: Int, total: Int) { Self.progress(of: id, in: tasks) }

    /// Everything pinned to the clock on a day, earliest first — the agenda.
    static func scheduled(_ all: [DayTask], on date: Date = Date()) -> [DayTask] {
        tasks(all, on: date)
            .filter { $0.schedule != nil }
            .sorted { ($0.schedule?.start ?? .distantPast) < ($1.schedule?.start ?? .distantPast) }
    }

    func scheduled(on date: Date = Date()) -> [DayTask] { Self.scheduled(tasks, on: date) }

    /// Every day that has tasks, newest first. The history screen's data source.
    var history: [DayGroup] { Self.history(from: tasks) }

    static func history(from all: [DayTask]) -> [DayGroup] {
        Dictionary(grouping: all, by: \.dayKey)
            .map { DayGroup(dayKey: $0.key, tasks: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.dayKey > $1.dayKey }   // "2026-09-28" > "2026-09-27" as strings too
    }

    /// Actionable tasks only: a task that has children is a container, and
    /// counting it would inflate every total the user sees.
    static func leaves(_ all: [DayTask], on date: Date = Date()) -> [DayTask] {
        let parents = Set(all.compactMap(\.parentID))
        return tasks(all, on: date).filter { !parents.contains($0.id) }
    }

    func leaves(on date: Date = Date()) -> [DayTask] { Self.leaves(tasks, on: date) }

    /// The only thing the widget calls. Reads disk and reduces it to a snapshot.
    static func snapshot(for date: Date = Date()) -> DaySnapshot {
        // Leaves, not every row: "Alışveriş > Migros > Süt" is one piece of
        // work on the Lock Screen, not three.
        let today = leaves(read(), on: date)
        return DaySnapshot(
            dayKey: DayKey.key(for: date),
            total: today.count,
            doneCount: today.filter(\.isDone).count,
            headline: headlineTask(from: today)
        )
    }

    /// Picks the single task the Lock Screen should show out of today's list.
    ///
    /// Hybrid rule: while work is left, show the oldest unfinished task — that
    /// is the one the tap-to-complete button should act on. Once everything is
    /// done, switch to the most recently finished task so the effort stays
    /// visible instead of the widget going blank.
    static func headlineTask(from todaysTasks: [DayTask]) -> DayTask? {
        if let next = todaysTasks.first(where: { !$0.isDone }) {
            return next
        }
        // Explicit scan rather than `max(by:)`: two tasks completed in the same
        // millisecond compare equal, and `max(by:)` keeps the *first* of those.
        // Scanning with `>=` keeps the last, so a tie resolves to the most
        // recently created task instead of the oldest one.
        var latest: DayTask?
        for task in todaysTasks where task.isDone {
            guard let current = latest else { latest = task; continue }
            if stamp(of: task) >= stamp(of: current) { latest = task }
        }
        return latest
    }

    /// When a task was finished, falling back to creation time for rows written
    /// before `completedAt` existed (or hand-edited JSON).
    private static func stamp(of task: DayTask) -> Date {
        task.completedAt ?? task.createdAt
    }
}
