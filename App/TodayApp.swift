import SwiftUI
import WidgetKit

@main
struct TodayApp: App {
    @StateObject private var store = TaskStore.shared
    @StateObject private var router = AppRouter()
    @StateObject private var schedule = ScheduleModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(router)
                .environmentObject(schedule)
                .onOpenURL { url in
                    // Arrived from the widget: fresh data first, then honour
                    // whatever the link asked for.
                    store.rolloverUnfinished()
                    router.handle(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.rolloverUnfinished()
                        WidgetCenter.shared.reloadAllTimelines()
                        // A session whose task was completed from the Lock
                        // Screen, or deleted elsewhere, is reconciled here.
                        Task { await FocusSession.refresh() }
                        // Fresh events, the widget told, and the island
                        // countdown started if a meeting is close.
                        schedule.reload()
                        CloudSync.shared.sync()
                    }
                }
        }
    }
}
