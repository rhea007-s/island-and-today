import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// Every day that has tasks, newest first. The data is already grouped and
/// sorted by `TaskStore.history` — this file is only about arranging it on
/// screen and letting a stretch of it leave the app.
struct HistoryView: View {
    @EnvironmentObject private var store: TaskStore

    var body: some View {
        List {
            ForEach(store.history) { day in
                Section {
                    ForEach(entries(of: day)) { entry in
                        HistoryRow(
                            task: entry.task,
                            depth: entry.depth,
                            progress: entry.isContainer
                                ? TaskStore.progress(of: entry.task.id, in: store.tasks)
                                : nil
                        )
                    }
                } header: {
                    Text(day.title)
                } footer: {
                    Text("\(day.doneCount) of \(day.totalCount) done")
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                exportMenu
            }
        }
        .overlay {
            if store.history.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "calendar",
                    description: Text("Days show up here once you add tasks to them.")
                )
            }
        }
    }

    // MARK: - Shaping a day

    /// Flattens one day into rows, depth-first, so the shape the user built
    /// survives on screen instead of every subtask sitting flush left.
    ///
    /// A root here is a task with no parent *or* one whose parent is not in this
    /// day: `rolloverUnfinished` moves an unfinished parent onto today and
    /// leaves its finished children behind, and a child nobody claims still has
    /// to draw rather than vanish from the record.
    private func entries(of day: DayGroup) -> [HistoryEntry] {
        let present = Set(day.tasks.map(\.id))
        var seen: Set<UUID> = []
        var out: [HistoryEntry] = []

        func walk(_ task: DayTask, depth: Int) {
            // A parent pointer that loops back on itself is bad data, not a
            // reason to spin forever.
            guard seen.insert(task.id).inserted else { return }
            let children = day.tasks.filter { $0.parentID == task.id }
            out.append(HistoryEntry(task: task, depth: depth, isContainer: !children.isEmpty))
            for child in children {
                walk(child, depth: depth + 1)
            }
        }

        for task in day.tasks where task.parentID.map({ !present.contains($0) }) ?? true {
            walk(task, depth: 0)
        }
        return out
    }

    // MARK: - Export

    private enum ExportRange: String, CaseIterable, Identifiable {
        case week, month, all
        var id: String { rawValue }

        var label: String {
            switch self {
            case .week:  "Last 7 days"
            case .month: "Last 30 days"
            case .all:   "Everything"
            }
        }

        /// Counted back from today inclusive, so "last 7 days" is today plus the
        /// six before it. `nil` means no lower bound at all.
        var daysBack: Int? {
            switch self {
            case .week:  6
            case .month: 29
            case .all:   nil
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(ExportRange.allCases) { range in
                Menu(range.label) {
                    ForEach(HistoryExport.Format.allCases) { format in
                        let document = document(for: range, as: format)
                        ShareLink(item: document, preview: SharePreview(document.filename)) {
                            Text(format.label)
                        }
                    }
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(store.history.isEmpty)
    }

    private func document(for range: ExportRange, as format: HistoryExport.Format) -> ExportDocument {
        let groups: [DayGroup]
        if let daysBack = range.daysBack,
           let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) {
            groups = HistoryExport.groups(from: store.tasks, from: start, to: Date())
        } else {
            groups = store.history
        }
        return ExportDocument(
            text: HistoryExport.render(groups, as: format, allTasks: store.tasks),
            filename: "Today \(DayKey.key()).\(format.fileExtension)"
        )
    }
}

/// One row of a day's tree: the task, how deep it sits, and whether it is a
/// container rather than a piece of work.
struct HistoryEntry: Identifiable {
    let task: DayTask
    let depth: Int
    let isContainer: Bool

    var id: UUID { task.id }
}

/// A rendered export carried as a file rather than a bare string, so the share
/// sheet offers "Save to Files" and Mail attaches it under the extension
/// `HistoryExport.Format` already knows about.
struct ExportDocument: Transferable {
    let text: String
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { document in
            Data(document.text.utf8)
        }
        .suggestedFileName { $0.filename }
    }
}

/// One finished-or-not task inside a day.
///
/// Read-only by design. `TaskRow` on the main screen is a `Button`, but here the
/// day is already filed: a row that looks tappable and does nothing is worse
/// than a row that plainly reads as a record.
struct HistoryRow: View {
    let task: DayTask
    var depth: Int = 0
    /// Non-nil when the task has subtasks. A container does no work of its own,
    /// so its branch's tally is the honest status rather than its own checkbox.
    var progress: (done: Int, total: Int)?

    private var isContainer: Bool { progress != nil }

    /// Finished, for whichever kind of row this is: a leaf answers for itself, a
    /// container answers for everything under it.
    private var isSettled: Bool {
        if let progress { return progress.total > 0 && progress.done == progress.total }
        return task.isDone
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            marker

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    // Containers are never struck through: the branch is done,
                    // the container was never the work.
                    .strikethrough(task.isDone && !isContainer)
                    .foregroundStyle(task.isDone ? Color.secondary : Color.primary)

                if let scheduleDetail {
                    Text(scheduleDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.leading, CGFloat(depth) * 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Deliberately calm: an unfinished day gets a hollow dotted circle, never a
    /// warning colour. A history that tells you off is a history you stop
    /// opening — and the footer already carries the day's real tally.
    private var marker: some View {
        Image(systemName: symbol)
            .imageScale(.medium)
            .foregroundStyle(isSettled ? Color.green : Color.secondary)
    }

    private var symbol: String {
        if isContainer {
            return isSettled ? "checkmark.circle.fill" : "circle.lefthalf.filled"
        }
        return task.isDone ? "checkmark.circle.fill" : "circle.dotted"
    }

    /// The two facts compete for one row, so they sit in different places: what
    /// the day *planned* goes under the title, what actually *happened* goes on
    /// the trailing edge.
    @ViewBuilder
    private var trailing: some View {
        if let progress {
            Text("\(progress.done)/\(progress.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if let completedAt = task.completedAt {
            Text(completedAt, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var scheduleDetail: String? {
        guard let schedule = task.schedule else { return nil }
        var parts: [String] = []
        if schedule.isAllDay {
            parts.append("All day")
        } else {
            let start = schedule.start.formatted(date: .omitted, time: .shortened)
            if let end = schedule.end, end != schedule.start {
                parts.append("\(start) – \(end.formatted(date: .omitted, time: .shortened))")
            } else {
                parts.append(start)
            }
        }
        if let location = schedule.location, !location.isEmpty {
            parts.append(location)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Spoken as one sentence. `children: .combine` would otherwise read the
    /// icon, the title and a bare time as three unrelated fragments.
    private var accessibilityLabel: String {
        var parts = [task.title]
        if let progress {
            parts.append("\(progress.done) of \(progress.total) done")
        } else {
            parts.append(task.isDone ? "done" : "not done")
            if let completedAt = task.completedAt {
                parts.append("at \(completedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        if let scheduleDetail { parts.append(scheduleDetail) }
        return parts.joined(separator: ", ")
    }
}

#Preview("History") {
    NavigationStack {
        HistoryView()
    }
    .environmentObject(TaskStore())
}

#Preview("Rows") {
    List {
        Section {
            HistoryRow(task: DayTask(title: "Ship the widget", isDone: true, completedAt: .now))
            HistoryRow(task: DayTask(title: "Call the bank"))
            HistoryRow(
                task: DayTask(
                    title: "Dentist",
                    schedule: TaskSchedule(
                        start: .now,
                        end: .now.addingTimeInterval(1800),
                        location: "Kadıköy"
                    )
                )
            )
            HistoryRow(task: DayTask(title: "Alışveriş"), progress: (done: 1, total: 3))
            HistoryRow(task: DayTask(title: "Süt", isDone: true, completedAt: .now), depth: 1)
            HistoryRow(task: DayTask(title: "Ekmek"), depth: 1)
        } header: {
            Text("Yesterday")
        } footer: {
            Text("2 of 5 done")
        }
    }
}
