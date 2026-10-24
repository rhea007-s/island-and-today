import ActivityKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var schedule: ScheduleModel
    @State private var draft = ""
    @State private var showingSync = false
    @ObservedObject private var cloud = CloudSync.shared
    /// Which task has a Live Activity running. ActivityKit has no publisher we
    /// can bind to, so this is re-read whenever something could have changed.
    @State private var focusedTaskID: UUID?
    @FocusState private var composerFocused: Bool

    private var today: [DayTask] {
        TaskStore.tasks(store.tasks, on: Date())
    }

    private var done: [DayTask] { today.filter(\.isDone) }
    private var open: [DayTask] { today.filter { !$0.isDone } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    composer
                }

                ScheduleSection(model: schedule)

                if let focusedTaskID, let task = today.first(where: { $0.id == focusedTaskID }) {
                    Section {
                        FocusBar(task: task) {
                            FocusSession.endAll()
                            self.focusedTaskID = nil
                        }
                    }
                }

                if !open.isEmpty {
                    Section("To do · \(open.count)") {
                        ForEach(open) { task in
                            TaskRow(task: task, isFocused: task.id == focusedTaskID) {
                                store.toggle(id: task.id)
                                Task { await FocusSession.refresh(); syncFocus() }
                            }
                            .swipeActions(edge: .leading) {
                                Button { startFocus(task, minutes: 25) } label: {
                                    Label("Focus", systemImage: "timer")
                                }
                                .tint(.indigo)
                            }
                            // The swipe picks the common case; the long press
                            // is where the other lengths live, so the default
                            // stays one gesture rather than a menu every time.
                            .contextMenu {
                                ForEach([15, 25, 50], id: \.self) { minutes in
                                    Button("Focus \(minutes) min", systemImage: "timer") {
                                        startFocus(task, minutes: minutes)
                                    }
                                }
                                Button("Focus, open-ended", systemImage: "stopwatch") {
                                    startFocus(task, minutes: nil)
                                }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { open[$0].id }.forEach(store.delete)
                        }
                    }
                }

                if !done.isEmpty {
                    Section("Done · \(done.count)") {
                        ForEach(done) { task in
                            TaskRow(task: task) { store.toggle(id: task.id) }
                        }
                        .onDelete { offsets in
                            offsets.map { done[$0].id }.forEach(store.delete)
                        }
                    }
                }

                if today.isEmpty {
                    Section {
                        Text("Nothing for today yet. Add the first thing above — it shows up on your Lock Screen right away.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide)))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSync = true } label: {
                        Image(systemName: cloud.isSignedIn ? "checkmark.icloud" : "icloud")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(done.count)/\(today.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showingSync) {
                NavigationStack {
                    Form { SyncView() }
                        .navigationTitle("Sync with Mac")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSync = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
            .task { syncFocus() }
            .onChange(of: store.tasks) { _, _ in
                Task { await FocusSession.refresh(); syncFocus() }
            }
            .onChange(of: router.wantsComposer) { _, wants in
                guard wants else { return }
                composerFocused = true
                // One-shot: consume the request so returning to the app later
                // does not pop the keyboard again.
                router.wantsComposer = false
            }
        }
    }

    private var composer: some View {
        HStack {
            TextField("What needs doing?", text: $draft)
                .focused($composerFocused)
                .submitLabel(.done)
                .onSubmit(commit)

            Button(action: commit) {
                Image(systemName: "arrow.up.circle.fill")
                    .imageScale(.large)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func commit() {
        store.add(draft)
        draft = ""
        composerFocused = true
    }

    /// `Activity.request` only succeeds from the foreground app, which is why
    /// starting lives here and not in the store.
    private func startFocus(_ task: DayTask, minutes: Int?) {
        FocusSession.start(task: task, minutes: minutes)
        // The request is asynchronous inside ActivityKit; read back on the next
        // turn of the loop rather than assuming it took.
        Task { @MainActor in syncFocus() }
    }

    private func syncFocus() {
        focusedTaskID = FocusSession.focusedTaskID
    }
}

/// The running session, shown in the app so the two surfaces never disagree
/// about what you are working on.
struct FocusBar: View {
    let task: DayTask
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "timer")
                .foregroundStyle(.indigo)

            VStack(alignment: .leading, spacing: 2) {
                Text("Focusing")
                    .font(.caption2)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }

            Spacer()

            Button("Stop", action: stop)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

struct TaskRow: View {
    let task: DayTask
    var isFocused: Bool = false
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(task.isDone ? .green : .secondary)

                Text(task.title)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)

                Spacer()

                if isFocused {
                    Image(systemName: "timer")
                        .imageScale(.small)
                        .foregroundStyle(.indigo)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .environmentObject(TaskStore())
        .environmentObject(AppRouter())
        .environmentObject(ScheduleModel())
}
