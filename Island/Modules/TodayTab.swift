import SwiftUI

/// Today's tasks — the same model, rules and file format as the iPhone app.
/// Tick, add, or start a focus session on any task straight from the notch.
struct TodayTab: View {
    let model: IslandModel
    @ObservedObject private var store = TaskStore.shared
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        let roots = store.roots()
        let leaves = store.leaves()
        let done = leaves.filter(\.isDone).count

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                if !leaves.isEmpty {
                    Text("\(done) of \(leaves.count)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                        .contentTransition(.numericText(value: Double(done)))
                }
            }

            ScheduleSection(model: model)

            if !leaves.isEmpty {
                ProgressView(value: Double(done), total: Double(max(1, leaves.count)))
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: done)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    if roots.isEmpty {
                        Text("Nothing yet — add the first thing below.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(roots) { task in
                        TaskRow(task: task, depth: 0, model: model)
                        ForEach(store.children(of: task.id)) { child in
                            TaskRow(task: child, depth: 1, model: model)
                        }
                    }
                }
            }
            .scrollIndicators(.never)

            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(model.settings.accent.color)
                TextField("Add a task for today", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($composing)
                    .onSubmit(add)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(composing ? 0.12 : 0.07)))
            .onTapGesture {
                // The panel never activates the app on its own; typing needs it
                // to be the key window first.
                NSApp.windows.first { $0 is IslandPanel }?.makeKey()
                composing = true
            }
        }
    }

    private func add() {
        guard store.add(draft) != nil else { return }
        draft = ""
        if model.settings.haptics { Haptics.tap() }
    }
}

private struct TaskRow: View {
    let task: DayTask
    let depth: Int
    let model: IslandModel
    @ObservedObject private var store = TaskStore.shared
    @State private var hovering = false

    private var focused: Bool { model.focus.isActive && model.focus.taskID == task.id }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { store.toggle(id: task.id) }
                if model.settings.haptics { Haptics.tap(strong: !task.isDone) }
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(task.isDone ? model.settings.accent.color : .white.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())

            Text(task.title)
                .font(.system(size: 13, weight: depth == 0 ? .medium : .regular))
                .strikethrough(task.isDone, color: .white.opacity(0.4))
                .foregroundStyle(task.isDone ? .white.opacity(0.4) : .white)
                .lineLimit(1)

            if let start = task.schedule?.start {
                Text(start, format: .dateTime.hour().minute())
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer(minLength: 6)

            if focused {
                Image(systemName: "scope")
                    .foregroundStyle(model.settings.accent.color)
                    .symbolEffect(.pulse)
            } else if hovering, !task.isDone {
                Button {
                    model.focus.start(taskID: task.id)
                    model.select(.focus)
                } label: {
                    Label("Focus", systemImage: "timer")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(ChipStyle())
                .transition(.opacity)
            }
        }
        .padding(.leading, CGFloat(depth) * 26 + 6)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.07 : 0)))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu {
            Button("Delete", role: .destructive) { store.delete(id: task.id) }
        }
    }
}
