import Foundation

/// Turns a stretch of history into something that can leave the app.
///
/// Deliberately pure: give it tasks, get back a string. No file handles, no
/// share sheet, no store — which is what makes it testable and what lets the
/// same output go to Mail, Notes, a file, or the clipboard.
enum HistoryExport {

    enum Format: String, CaseIterable, Identifiable {
        case markdown, csv, plain
        var id: String { rawValue }

        var label: String {
            switch self {
            case .markdown: "Markdown"
            case .csv:      "CSV"
            case .plain:    "Plain text"
            }
        }

        var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .csv:      "csv"
            case .plain:    "txt"
            }
        }
    }

    /// Days that fall inside the range, newest first, each with its tasks.
    static func groups(from all: [DayTask], from startDate: Date, to endDate: Date) -> [DayGroup] {
        let lower = min(DayKey.key(for: startDate), DayKey.key(for: endDate))
        let upper = max(DayKey.key(for: startDate), DayKey.key(for: endDate))
        let inRange = all.filter { $0.dayKey >= lower && $0.dayKey <= upper }
        return TaskStore.history(from: inRange)
    }

    static func render(_ groups: [DayGroup], as format: Format, allTasks: [DayTask]) -> String {
        switch format {
        case .markdown: markdown(groups, allTasks: allTasks)
        case .csv:      csv(groups)
        case .plain:    plain(groups, allTasks: allTasks)
        }
    }

    // MARK: - Renderers

    private static func markdown(_ groups: [DayGroup], allTasks: [DayTask]) -> String {
        var out: [String] = []
        for group in groups {
            out.append("## \(group.title)")
            out.append("")
            for task in group.tasks where task.parentID == nil {
                out.append(contentsOf: lines(for: task, in: allTasks, depth: 0) { task, indent in
                    "\(indent)- [\(task.isDone ? "x" : " ")] \(task.title)\(suffix(for: task))"
                })
            }
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plain(_ groups: [DayGroup], allTasks: [DayTask]) -> String {
        var out: [String] = []
        for group in groups {
            out.append("\(group.title) — \(group.doneCount)/\(group.totalCount)")
            for task in group.tasks where task.parentID == nil {
                out.append(contentsOf: lines(for: task, in: allTasks, depth: 0) { task, indent in
                    "\(indent)\(task.isDone ? "✓" : "·") \(task.title)\(suffix(for: task))"
                })
            }
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func csv(_ groups: [DayGroup]) -> String {
        var rows = ["day,title,done,completed_at,start,end,location"]
        let iso = ISO8601DateFormatter()
        for group in groups {
            for task in group.tasks {
                rows.append([
                    group.dayKey,
                    task.title,
                    task.isDone ? "yes" : "no",
                    task.completedAt.map(iso.string(from:)) ?? "",
                    task.schedule.map { iso.string(from: $0.start) } ?? "",
                    task.schedule?.end.map(iso.string(from:)) ?? "",
                    task.schedule?.location ?? ""
                ].map(escape).joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Walks a task and its descendants, indenting as it goes, so the exported
    /// text keeps the shape the user built rather than flattening it.
    private static func lines(
        for task: DayTask,
        in all: [DayTask],
        depth: Int,
        render: (DayTask, String) -> String
    ) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var out = [render(task, indent)]
        for child in TaskStore.children(of: task.id, in: all) {
            out.append(contentsOf: lines(for: child, in: all, depth: depth + 1, render: render))
        }
        return out
    }

    private static func suffix(for task: DayTask) -> String {
        guard let schedule = task.schedule else { return "" }
        var parts: [String] = []
        if schedule.isAllDay {
            parts.append("all day")
        } else {
            let time = schedule.start.formatted(date: .omitted, time: .shortened)
            if let end = schedule.end, end != schedule.start {
                parts.append("\(time)–\(end.formatted(date: .omitted, time: .shortened))")
            } else {
                parts.append(time)
            }
        }
        if let location = schedule.location, !location.isEmpty { parts.append(location) }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }

    /// A field holding a comma, quote or newline has to be quoted, and inner
    /// quotes doubled — otherwise one task title with a comma shifts every
    /// column after it.
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
