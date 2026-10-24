import ActivityKit
import AppIntents
import WidgetKit

/// Finishes the focused task from the Live Activity itself.
///
/// Mirrors `ToggleTaskIntent`, but it is not the same intent: this one always
/// *completes* (a focus session has no reason to un-finish anything) and it
/// closes the session afterwards.
struct CompleteFocusIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Focused Task"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}

    init(taskID: String) {
        self.taskID = taskID
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { return .result() }

        TaskStore.mutateFromExtension { tasks in
            guard let i = tasks.firstIndex(where: { $0.id == id }), !tasks[i].isDone else { return }
            TaskStore.applyToggle(id: id, to: &tasks)
        }

        // `refresh` pushes the finished state and then ends the session, so
        // the last frame the user sees is the task ticked off.
        await FocusSession.refresh()
        return .result()
    }
}

/// Drops the session without touching the task — you stopped working on it,
/// you did not finish it.
struct EndFocusIntent: AppIntent {
    static var title: LocalizedStringResource = "End Focus Session"
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        await FocusSession.endCurrent(reason: .cancelled)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
