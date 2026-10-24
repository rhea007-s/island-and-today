import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// The live session that sits on the Lock Screen and in the Dynamic Island
/// while you are actually working on one task.
///
/// Compiled into both targets: ActivityKit matches an activity to its UI by
/// the *type*, so the app that requests it and the widget that renders it have
/// to agree on exactly this declaration.
struct FocusAttributes: ActivityAttributes {
    /// Everything that can change while the session is running. Kept small —
    /// each update is a system-wide IPC, not a local assignment.
    struct ContentState: Codable, Hashable {
        /// Carried in the state rather than the attributes so a rename in the
        /// app reaches a session that is already on screen.
        var taskTitle: String
        var isDone: Bool
        /// Unfinished leaves left today, so the island can say what remains
        /// after this one without reading the store from the render pass.
        var remainingToday: Int
        var startedAt: Date
        /// `nil` means an open-ended stopwatch rather than a countdown.
        var plannedEnd: Date?

        /// The window the system's own timer text should run over. Counting up
        /// has no end, so it gets an hour-long ceiling the label never reaches.
        var timerRange: ClosedRange<Date> {
            let end = plannedEnd ?? startedAt.addingTimeInterval(60 * 60)
            // A planned end that already passed would make an empty range and
            // crash the label; keep at least a second of span.
            return startedAt...max(end, startedAt.addingTimeInterval(1))
        }

        var countsDown: Bool { plannedEnd != nil }

        /// True once a countdown session runs past the time it was given.
        var isOverrun: Bool {
            guard let plannedEnd else { return false }
            return !isDone && Date() >= plannedEnd
        }
    }

    /// Which task this session belongs to. Fixed for the life of the activity,
    /// which is what lets the intents act on it without any lookup.
    var taskID: String
}

#if canImport(ActivityKit)

/// Starting, updating and ending the one focus session.
///
/// Deliberately a single-session model: two Live Activities for the same app
/// stack on the Lock Screen and neither one reads as "what I am doing now".
enum FocusSession {

    /// Every focus activity this process can see. The widget extension sees
    /// the same list the app does — that is how an intent can end a session
    /// the app started.
    static var activities: [Activity<FocusAttributes>] {
        Activity<FocusAttributes>.activities
    }

    static var current: Activity<FocusAttributes>? { activities.first }

    static func activity(for taskID: UUID) -> Activity<FocusAttributes>? {
        activities.first { $0.attributes.taskID == taskID.uuidString }
    }

    static var isRunning: Bool { current != nil }

    /// The task currently in focus, if any — so the app can badge its row.
    static var focusedTaskID: UUID? {
        current.flatMap { UUID(uuidString: $0.attributes.taskID) }
    }

    // MARK: - Lifecycle

    /// Requests a session for `task`. `minutes` of `nil` starts a stopwatch.
    ///
    /// Only the app may call this: ActivityKit rejects a request from an
    /// extension, and from the background.
    @discardableResult
    static func start(task: DayTask, minutes: Int? = nil) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }

        // One at a time. Ending first keeps the Lock Screen from briefly
        // showing two sessions while the new one spins up.
        endAll(reason: .switched)

        let now = Date()
        let state = FocusAttributes.ContentState(
            taskTitle: task.title,
            isDone: task.isDone,
            remainingToday: remainingCount(excluding: task.id),
            startedAt: now,
            plannedEnd: minutes.map { now.addingTimeInterval(TimeInterval($0) * 60) }
        )

        do {
            _ = try Activity.request(
                attributes: FocusAttributes(taskID: task.id.uuidString),
                content: .init(state: state, staleDate: staleDate(from: state)),
                pushType: nil
            )
            return true
        } catch {
            return false
        }
    }

    /// Re-reads the store and pushes the current truth into the live session.
    /// Called after any mutation the session's content depends on.
    static func refresh() async {
        guard let activity = current,
              let id = UUID(uuidString: activity.attributes.taskID)
        else { return }

        let tasks = TaskStore.read()
        guard let task = tasks.first(where: { $0.id == id }) else {
            // The task was deleted out from under the session.
            await end(activity, reason: .cancelled)
            return
        }

        var state = activity.content.state
        state.taskTitle = task.title
        state.isDone = task.isDone
        state.remainingToday = remainingCount(excluding: id, in: tasks)

        await activity.update(.init(state: state, staleDate: staleDate(from: state)))

        // A finished task should linger just long enough to register as done,
        // then clear itself rather than sitting on the Lock Screen all day.
        if task.isDone { await end(activity, reason: .completed) }
    }

    enum EndReason {
        case completed, cancelled, switched

        /// How long the final frame stays up. A completion earns a beat of
        /// acknowledgement; a swap or a cancel should vanish at once.
        var dismissal: ActivityUIDismissalPolicy {
            switch self {
            case .completed: return .after(Date().addingTimeInterval(8))
            case .cancelled, .switched: return .immediate
            }
        }
    }

    static func end(_ activity: Activity<FocusAttributes>, reason: EndReason) async {
        var state = activity.content.state
        if reason == .completed { state.isDone = true }
        await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: reason.dismissal)
    }

    static func endCurrent(reason: EndReason = .cancelled) async {
        guard let activity = current else { return }
        await end(activity, reason: reason)
    }

    /// Fire-and-forget variant for call sites that are not async — a button
    /// action, or the moment just before a new session is requested.
    static func endAll(reason: EndReason = .cancelled) {
        for activity in activities {
            Task { await end(activity, reason: reason) }
        }
    }

    // MARK: - Helpers

    /// When the system should start treating the content as out of date —
    /// the moment the countdown runs out, or an hour into a stopwatch.
    private static func staleDate(from state: FocusAttributes.ContentState) -> Date {
        state.plannedEnd ?? state.startedAt.addingTimeInterval(60 * 60)
    }

    private static func remainingCount(excluding id: UUID, in tasks: [DayTask]? = nil) -> Int {
        let all = tasks ?? TaskStore.read()
        return TaskStore.leaves(all).filter { !$0.isDone && $0.id != id }.count
    }
}

#endif
