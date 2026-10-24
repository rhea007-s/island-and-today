import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - The widget declaration

struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusAttributes.self) { context in
            // Lock Screen and the banner on older devices.
            FocusLockScreenView(state: context.state, taskID: context.attributes.taskID)
                .widgetURL(AppGroup.url(AppGroup.Route.today))
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.primary)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isDone ? "checkmark.circle.fill" : "timer")
                        .font(.title2)
                        .foregroundStyle(context.state.isDone ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tint))
                        .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    FocusTimerText(state: context.state)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(context.state.isOverrun ? .orange : .primary)
                        .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.taskTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .strikethrough(context.state.isDone)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Button(intent: EndFocusIntent()) {
                            Label("Stop", systemImage: "xmark")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)

                        Button(intent: CompleteFocusIntent(taskID: context.attributes.taskID)) {
                            Label("Done", systemImage: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(context.state.isDone)
                    }
                    .padding(.top, 2)
                }

            } compactLeading: {
                CompactFocusView(state: context.state, slot: .leading)
            } compactTrailing: {
                CompactFocusView(state: context.state, slot: .trailing)
            } minimal: {
                CompactFocusView(state: context.state, slot: .minimal)
            }
            .widgetURL(AppGroup.url(AppGroup.Route.today))
            .keylineTint(.accentColor)
        }
    }
}

// MARK: - Lock Screen

struct FocusLockScreenView: View {
    let state: FocusAttributes.ContentState
    let taskID: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .imageScale(.small)
                    Text(statusLine)
                        .font(.caption2)
                        .textCase(.uppercase)
                }
                .foregroundStyle(.secondary)

                Text(state.taskTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .strikethrough(state.isDone)

                FocusTimerText(state: state)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(state.isOverrun ? .orange : .primary)
            }

            Spacer(minLength: 0)

            // Tick it off without unlocking — the same promise the Lock Screen
            // widget already makes, kept while the session is running.
            Button(intent: CompleteFocusIntent(taskID: taskID)) {
                Image(systemName: state.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 40))
                    .foregroundStyle(state.isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(state.isDone)
        }
        .padding()
    }

    private var statusLine: String {
        if state.isDone { return "Done" }
        if state.isOverrun { return "Over" }
        if state.remainingToday == 0 { return "Last one today" }
        return "Focusing · \(state.remainingToday) more today"
    }
}

// MARK: - The timer label

/// One label for both session shapes. `Text(timerInterval:)` is rendered and
/// advanced by the system, so a running clock costs no activity updates.
struct FocusTimerText: View {
    let state: FocusAttributes.ContentState

    var body: some View {
        if state.isDone {
            Text("Done")
        } else {
            Text(timerInterval: state.timerRange,
                 pauseTime: nil,
                 countsDown: state.countsDown,
                 showsHours: false)
        }
    }
}

// MARK: - Dynamic Island, compact and minimal

/// The three tight presentations. Each gets a handful of points beside the
/// camera, so whatever goes here has to be readable at a glance and legible
/// at that size.
struct CompactFocusView: View {
    enum Slot { case leading, trailing, minimal }

    let state: FocusAttributes.ContentState
    let slot: Slot

    var body: some View {
        switch slot {
        case .leading, .minimal:
            // The glyph alone: it says "a focus session" before the eye
            // reaches the clock, and it is all the minimal slot has room for.
            Image(systemName: state.isDone ? "checkmark.circle.fill" : "timer")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(state.isDone ? AnyShapeStyle(Color.green)
                                 : state.isOverrun ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint))
        case .trailing:
            FocusTimerText(state: state)
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(state.isOverrun ? .orange : .primary)
                .multilineTextAlignment(.trailing)
                // The timer label is as wide as it is allowed to be; pin it so
                // it does not push the island out to full width.
                .frame(maxWidth: 46)
        }
    }
}

// MARK: - Previews

#Preview("Lock Screen", as: .content, using: FocusAttributes.preview) {
    FocusLiveActivity()
} contentStates: {
    FocusAttributes.ContentState.previewCountdown
    FocusAttributes.ContentState.previewStopwatch
    FocusAttributes.ContentState.previewOverrun
    FocusAttributes.ContentState.previewDone
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: FocusAttributes.preview) {
    FocusLiveActivity()
} contentStates: {
    FocusAttributes.ContentState.previewCountdown
    FocusAttributes.ContentState.previewDone
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: FocusAttributes.preview) {
    FocusLiveActivity()
} contentStates: {
    FocusAttributes.ContentState.previewCountdown
    FocusAttributes.ContentState.previewOverrun
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: FocusAttributes.preview) {
    FocusLiveActivity()
} contentStates: {
    FocusAttributes.ContentState.previewCountdown
    FocusAttributes.ContentState.previewDone
}

extension FocusAttributes {
    static var preview: FocusAttributes {
        FocusAttributes(taskID: UUID().uuidString)
    }
}

extension FocusAttributes.ContentState {
    static var previewCountdown: Self {
        .init(taskTitle: "Draft the quarterly note", isDone: false, remainingToday: 3,
              startedAt: Date().addingTimeInterval(-7 * 60),
              plannedEnd: Date().addingTimeInterval(18 * 60))
    }

    static var previewStopwatch: Self {
        .init(taskTitle: "Read the contract", isDone: false, remainingToday: 1,
              startedAt: Date().addingTimeInterval(-12 * 60), plannedEnd: nil)
    }

    static var previewOverrun: Self {
        .init(taskTitle: "Call the bank", isDone: false, remainingToday: 2,
              startedAt: Date().addingTimeInterval(-40 * 60),
              plannedEnd: Date().addingTimeInterval(-5 * 60))
    }

    static var previewDone: Self {
        .init(taskTitle: "Ship the widget", isDone: true, remainingToday: 0,
              startedAt: Date().addingTimeInterval(-25 * 60),
              plannedEnd: Date().addingTimeInterval(5 * 60))
    }
}
