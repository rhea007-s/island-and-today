import AppIntents
import WidgetKit

/// Lets you tick a task off straight from the Lock Screen — no app launch.
/// This is what makes the widget a control surface instead of a poster.
struct ToggleTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Task"
    /// Keeps the tap silent: no app foregrounding, no Siri confirmation.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}

    init(taskID: UUID) {
        self.taskID = taskID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { return .result() }
        TaskStore.mutateFromExtension { TaskStore.applyToggle(id: id, to: &$0) }
        return .result()
    }
}
