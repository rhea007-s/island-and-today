import SwiftUI
import WidgetKit

// MARK: - Circular: a progress ring with done/total in the middle

struct CircularView: View {
    let snapshot: DaySnapshot

    var body: some View {
        Gauge(value: snapshot.progress) {
            Image(systemName: snapshot.allDone ? "checkmark" : "checklist")
        } currentValueLabel: {
            if snapshot.isEmpty {
                Image(systemName: "plus")
            } else {
                Text("\(snapshot.doneCount)")
                    .contentTransition(.numericText())
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Rectangular: the headline task, tappable

struct RectangularView: View {
    let snapshot: DaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: statusIcon)
                    .imageScale(.small)
                Text(statusLine)
                    .font(.caption2)
                    .textCase(.uppercase)
            }
            .widgetAccentable()

            if let headline = snapshot.headline {
                // Tapping the row completes the task in place.
                Button(intent: ToggleTaskIntent(taskID: headline.id)) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: headline.isDone ? "checkmark.circle.fill" : "circle")
                            .imageScale(.small)
                        Text(headline.title)
                            .font(.headline)
                            .lineLimit(2)
                            .strikethrough(headline.isDone)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(emptyLine)
                    .font(.headline)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var statusIcon: String {
        if snapshot.isEmpty { return "tray" }
        return snapshot.allDone ? "checkmark.seal.fill" : "checklist"
    }

    private var statusLine: String {
        if snapshot.isEmpty { return "Today" }
        if snapshot.allDone { return "All done · \(snapshot.total)" }
        return "\(snapshot.doneCount)/\(snapshot.total) done"
    }

    private var emptyLine: String {
        if snapshot.allDone { return "Nothing left today" }
        return snapshot.isEmpty ? "Add something to do" : "Nothing left today"
    }
}

// MARK: - Inline: one line above the clock

struct InlineView: View {
    let snapshot: DaySnapshot

    var body: some View {
        if snapshot.isEmpty {
            Label("No tasks today", systemImage: "tray")
        } else if snapshot.allDone {
            Label("All \(snapshot.total) done", systemImage: "checkmark.seal.fill")
        } else if let headline = snapshot.headline {
            Label("\(snapshot.remaining) left · \(headline.title)", systemImage: "checklist")
        } else {
            Label("\(snapshot.remaining) left today", systemImage: "checklist")
        }
    }
}

// MARK: - Home Screen small, for the same data

struct SmallHomeView: View {
    let snapshot: DaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.doneCount)/\(snapshot.total)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: snapshot.progress)
                .tint(snapshot.allDone ? .green : .accentColor)

            if let headline = snapshot.headline {
                Text(headline.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .strikethrough(headline.isDone)
            } else {
                Text(snapshot.allDone ? "All clear 🎉" : "Nothing planned")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

// MARK: - Family switch

struct TodayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DayEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularView(snapshot: entry.snapshot)
        case .accessoryInline:
            InlineView(snapshot: entry.snapshot)
        case .accessoryRectangular:
            RectangularView(snapshot: entry.snapshot)
        default:
            SmallHomeView(snapshot: entry.snapshot)
        }
    }
}
