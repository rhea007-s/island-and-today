import ActivityKit
import SwiftUI
import WidgetKit

/// The next event, counting down in the Dynamic Island — the same thing the
/// Mac island shows in its wings. iPhones without a Dynamic Island get the
/// Lock Screen card and a banner instead.
struct MeetingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingAttributes.self) { context in
            MeetingLockScreenView(attributes: context.attributes, state: context.state,
                                  started: Self.started(context))
                .widgetURL(AppGroup.calendarURL(at: context.state.start))
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            let color = Self.color(context.attributes)
            let started = Self.started(context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "calendar")
                        .font(.title2)
                        .foregroundStyle(color)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MeetingClock(state: context.state, started: started)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(color)
                        .frame(maxWidth: 90, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(context.state.start, format: .dateTime.hour().minute()) – \(context.state.end, format: .dateTime.hour().minute())")
                                .font(.subheadline.weight(.medium))
                            if let place = context.state.location {
                                Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if let url = context.attributes.joinURL, let link = AppGroup.joinURL(url) {
                            Link(destination: link) {
                                Label("Join", systemImage: "video.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(.green))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "calendar")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(color)
            } compactTrailing: {
                MeetingClock(state: context.state, started: started, short: true)
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 46)
            } minimal: {
                Image(systemName: started ? "calendar.badge.clock" : "calendar")
                    .foregroundStyle(color)
            }
            .widgetURL(AppGroup.calendarURL(at: context.state.start))
            .keylineTint(color)
        }
    }

    /// Stale means the start time has passed (see `MeetingSession.start`).
    static func started(_ context: ActivityViewContext<MeetingAttributes>) -> Bool {
        context.isStale || context.state.start <= Date()
    }

    static func color(_ a: MeetingAttributes) -> Color {
        a.rgb.count == 3 ? Color(red: a.rgb[0], green: a.rgb[1], blue: a.rgb[2]) : .red
    }
}

/// Counts down to the start, then down to the end.
struct MeetingClock: View {
    let state: MeetingAttributes.ContentState
    let started: Bool
    var short = false

    var body: some View {
        if started {
            if short {
                Text("now")
            } else {
                Text(timerInterval: state.untilEnd, countsDown: true, showsHours: false)
            }
        } else {
            Text(timerInterval: state.untilStart, countsDown: true, showsHours: false)
        }
    }
}

struct MeetingLockScreenView: View {
    let attributes: MeetingAttributes
    let state: MeetingAttributes.ContentState
    let started: Bool

    private var color: Color { MeetingLiveActivity.color(attributes) }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 3) {
                Label(started ? "Now" : "Up next", systemImage: "calendar")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(color)
                Text(state.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(state.start, format: .dateTime.hour().minute()) – \(state.end, format: .dateTime.hour().minute())\(state.location.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                MeetingClock(state: state, started: started)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 96, alignment: .trailing)
                if let url = attributes.joinURL, let link = AppGroup.joinURL(url) {
                    Link(destination: link) {
                        Label("Join", systemImage: "video.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.green))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - Previews

#Preview("Lock Screen", as: .content, using: MeetingAttributes.preview) {
    MeetingLiveActivity()
} contentStates: {
    MeetingAttributes.ContentState.preview
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: MeetingAttributes.preview) {
    MeetingLiveActivity()
} contentStates: {
    MeetingAttributes.ContentState.preview
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: MeetingAttributes.preview) {
    MeetingLiveActivity()
} contentStates: {
    MeetingAttributes.ContentState.preview
}

extension MeetingAttributes {
    static var preview: MeetingAttributes {
        MeetingAttributes(eventID: "standup", rgb: [0.2, 0.5, 1], joinURL: URL(string: "https://meet.google.com/abc"))
    }
}

extension MeetingAttributes.ContentState {
    static var preview: Self {
        .init(title: "Team standup", start: Date().addingTimeInterval(8 * 60),
              end: Date().addingTimeInterval(38 * 60), location: "Room 4")
    }
}
