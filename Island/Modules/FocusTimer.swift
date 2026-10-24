import SwiftUI
import Observation

/// A Pomodoro clock that can be pinned to one of today's tasks.
///
/// Time is stored as an *end date*, never as a ticking counter: the Mac can
/// sleep, the app can quit, and on the way back the remaining time is simply
/// `end - now`. The session survives a relaunch through UserDefaults.
@MainActor
@Observable
final class FocusTimer {
    enum Phase: String { case work, rest }

    private(set) var phase: Phase = .work
    private(set) var endDate: Date?
    /// Set while paused: the time that was left when the pause began.
    private(set) var pausedRemaining: TimeInterval?
    private(set) var duration: TimeInterval = 25 * 60
    private(set) var taskID: UUID?
    private(set) var sessionsToday = 0

    weak var settings: IslandSettings?
    var onFinish: ((Phase) -> Void)?

    private var tick: Timer?
    private let defaults = UserDefaults.standard

    init() { restore() }

    var isRunning: Bool { endDate != nil }
    var isPaused: Bool { pausedRemaining != nil }
    var isActive: Bool { isRunning || isPaused }

    var task: DayTask? {
        guard let taskID else { return nil }
        return TaskStore.shared.tasks.first { $0.id == taskID }
    }

    func remaining(at date: Date) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let endDate else { return duration }
        return max(0, endDate.timeIntervalSince(date))
    }

    func progress(at date: Date) -> Double {
        guard isActive, duration > 0 else { return 0 }
        return 1 - remaining(at: date) / duration
    }

    // MARK: - Controls

    func start(minutes: Int? = nil, phase: Phase = .work, taskID: UUID? = nil) {
        let fallback = phase == .work ? (settings?.focusMinutes ?? 25) : (settings?.breakMinutes ?? 5)
        self.phase = phase
        duration = TimeInterval(max(1, minutes ?? fallback) * 60)
        if phase == .work { self.taskID = taskID ?? self.taskID }
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(duration)
        schedule()
        save()
    }

    func pause() {
        guard let endDate else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        self.endDate = nil
        tick?.invalidate()
        save()
    }

    func resume() {
        guard let pausedRemaining else { return }
        endDate = Date().addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
        schedule()
        save()
    }

    func stop() {
        endDate = nil
        pausedRemaining = nil
        phase = .work
        tick?.invalidate()
        save()
    }

    func attach(_ id: UUID?) {
        taskID = id
        save()
    }

    // MARK: - Finishing

    /// One timer, fired at the end date — not a once-a-second poll. The
    /// countdown text on screen is drawn by the system's own timer label.
    private func schedule() {
        tick?.invalidate()
        guard let endDate else { return }
        let timer = Timer(fire: endDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func finish() {
        let ended = phase
        endDate = nil
        pausedRemaining = nil

        if ended == .work {
            bumpSessions()
            if settings?.autoStartBreak ?? true {
                start(phase: .rest)
            } else {
                phase = .work
                save()
            }
        } else {
            phase = .work
            save()
        }
        onFinish?(ended)
    }

    private func bumpSessions() {
        let key = "focusSessions-\(DayKey.key())"
        sessionsToday = defaults.integer(forKey: key) + 1
        defaults.set(sessionsToday, forKey: key)
    }

    // MARK: - Persistence

    private func save() {
        defaults.set(phase.rawValue, forKey: "focus.phase")
        defaults.set(endDate, forKey: "focus.end")
        defaults.set(pausedRemaining, forKey: "focus.paused")
        defaults.set(duration, forKey: "focus.duration")
        defaults.set(taskID?.uuidString, forKey: "focus.task")
    }

    private func restore() {
        sessionsToday = defaults.integer(forKey: "focusSessions-\(DayKey.key())")
        phase = Phase(rawValue: defaults.string(forKey: "focus.phase") ?? "") ?? .work
        let saved = defaults.double(forKey: "focus.duration")
        duration = saved > 0 ? saved : 25 * 60
        taskID = defaults.string(forKey: "focus.task").flatMap(UUID.init(uuidString:))
        pausedRemaining = defaults.object(forKey: "focus.paused") as? TimeInterval
        if let end = defaults.object(forKey: "focus.end") as? Date {
            if end > Date() {
                endDate = end
                schedule()
            } else {
                // Ended while the app was closed: count it, don't ring late.
                endDate = nil
                if phase == .work { bumpSessions() }
                phase = .work
                save()
            }
        }
    }
}

/// "12:34" that the system keeps counting down on its own — no per-second
/// view updates from us. Frozen with a pause glyph while paused.
struct FocusClock: View {
    let timer: FocusTimer
    var size: CGFloat

    var body: some View {
        Group {
            if let end = timer.endDate {
                Text(timerInterval: Date()...max(end, Date().addingTimeInterval(1)), countsDown: true, showsHours: false)
            } else {
                HStack(spacing: 3) {
                    if timer.isPaused { Image(systemName: "pause.fill").font(.system(size: size * 0.7)) }
                    Text(Duration.seconds(timer.remaining(at: .now)).formatted(.time(pattern: .minuteSecond)))
                }
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }
}

struct FocusTab: View {
    let model: IslandModel
    @ObservedObject private var store = TaskStore.shared

    private var timer: FocusTimer { model.focus }
    private var accent: Color { timer.phase == .work ? model.settings.accent.color : .green }

    var body: some View {
        HStack(spacing: 26) {
            ZStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    FocusRing(progress: timer.progress(at: context.date), lineWidth: 7, color: accent)
                }
                VStack(spacing: 2) {
                    FocusClock(timer: timer, size: 30)
                    Text(timer.isActive ? (timer.phase == .work ? "focus" : "break") : "ready")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 150, height: 150)
            .animation(.spring(response: 0.4, dampingFraction: 1), value: timer.isActive)

            VStack(alignment: .leading, spacing: 14) {
                taskPicker

                HStack(spacing: 8) {
                    if timer.isRunning {
                        pill("Pause", "pause.fill") { timer.pause() }
                    } else if timer.isPaused {
                        pill("Resume", "play.fill", primary: true) { timer.resume() }
                    } else {
                        pill("Start \(model.settings.focusMinutes) min", "play.fill", primary: true) {
                            timer.start(taskID: timer.taskID)
                        }
                    }
                    if timer.isActive {
                        pill("Stop", "stop.fill") { timer.stop() }
                    }
                }

                if !timer.isActive {
                    HStack(spacing: 6) {
                        ForEach([15, 25, 50], id: \.self) { m in
                            Button("\(m)m") { timer.start(minutes: m, taskID: timer.taskID) }
                                .buttonStyle(ChipStyle())
                        }
                        Button("Break") { timer.start(phase: .rest) }
                            .buttonStyle(ChipStyle())
                    }
                }

                if let task = timer.task, !task.isDone, timer.isActive {
                    Button {
                        store.toggle(id: task.id)
                        timer.stop()
                        if model.settings.haptics { Haptics.tap(strong: true) }
                    } label: {
                        Label("Mark \"\(task.title)\" done", systemImage: "checkmark.circle")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.75))
                }

                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    ForEach(0..<max(4, timer.sessionsToday), id: \.self) { i in
                        Circle()
                            .fill(i < timer.sessionsToday ? accent : .white.opacity(0.15))
                            .frame(width: 7, height: 7)
                    }
                    Text("\(timer.sessionsToday) today")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.leading, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var taskPicker: some View {
        let open = TaskStore.leaves(store.tasks).filter { !$0.isDone }
        return Menu {
            Button("No task") { timer.attach(nil) }
            Divider()
            ForEach(open) { task in
                Button(task.title) { timer.attach(task.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                Text(timer.task?.title ?? "Pick a task to focus on")
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(timer.task == nil ? .white.opacity(0.6) : .white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func pill(_ title: String, _ symbol: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) { action() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .foregroundStyle(primary ? Color.black : .white)
                .background(Capsule().fill(primary ? accent : .white.opacity(0.12)))
        }
        .buttonStyle(PressableStyle())
    }
}

struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .foregroundStyle(.white.opacity(0.8))
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.2 : 0.09)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}
