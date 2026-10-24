import SwiftUI
import Observation

/// The three shapes the island takes.
///
/// - compact:  sits in the notch; grows small "wings" only while something is
///             live (a focus session, music).
/// - peek:     hovered — one extra line drops down with today's next task.
/// - expanded: clicked — the full panel with tabs.
enum IslandState: Equatable {
    case compact, peek, expanded
}

enum IslandTab: String, CaseIterable, Identifiable {
    case today, focus, music, clipboard, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .focus: "Focus"
        case .music: "Music"
        case .clipboard: "Clipboard"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .today: "checklist"
        case .focus: "timer"
        case .music: "music.note"
        case .clipboard: "doc.on.clipboard"
        case .system: "cpu"
        }
    }
}

/// What the compact island shows in its wings. One thing at a time, in this
/// order: a running focus session is the reason you are at the desk, so it
/// beats whatever happens to be playing.
enum LiveActivity: Equatable {
    case focus, meeting(CalendarFeed.Event), music, none
}

@MainActor
@Observable
final class IslandModel {
    var state: IslandState = .compact
    var tab: IslandTab = .today
    /// +1 when the last tab change moved right, -1 left — so the new content
    /// slides in from the side of the icon that was clicked.
    private(set) var tabDirection: CGFloat = 1

    var geometry = NotchGeometry.fallback

    let settings = IslandSettings()
    let focus = FocusTimer()
    let music = NowPlaying()
    let clipboard = ClipboardHistory()
    let system = SystemMonitor()
    let claude = ClaudeUsage()
    let calendar = CalendarFeed()
    let tasks = TaskStore.shared

    /// A short message the island drops down to say on its own — a focus
    /// session ending, mostly. Cleared after a few seconds.
    var banner: Banner?

    init() {
        focus.settings = settings
        focus.onFinish = { [weak self] phase in self?.focusFinished(phase) }
        music.start()
        calendar.settings = settings
        calendar.start()
        claude.startBackground()
        if settings.clipboardEnabled { clipboard.start() }
    }

    // MARK: - What to show

    var activity: LiveActivity {
        if focus.isActive { return .focus }
        // A meeting about to start beats music: missing it costs more.
        if let event = calendar.soon() { return .meeting(event) }
        if settings.showMusicInCompact, music.isPlaying { return .music }
        return .none
    }

    /// Wings exist only while something is live; otherwise the island is the
    /// notch itself and nothing more.
    var showsWings: Bool { activity != .none || banner != nil }

    /// The notch on a Mac that has one; on any other display, the pill the
    /// user sized in Settings.
    var baseSize: CGSize {
        geometry.hasNotch
            ? geometry.notchSize
            : CGSize(width: settings.pillWidth, height: max(geometry.notchSize.height, settings.pillHeight))
    }

    var size: CGSize {
        let base = baseSize
        let wing = settings.wingWidth
        switch state {
        case .compact:
            return CGSize(width: base.width + (showsWings ? wing * 2 : 0), height: base.height + (banner != nil ? 30 : 0))
        case .peek:
            return CGSize(width: base.width + wing * 2 + 40, height: base.height + 46)
        case .expanded:
            return CGSize(width: max(settings.expandedWidth, base.width + 300), height: base.height + settings.expandedHeight)
        }
    }

    /// Top flare and bottom corner of the outline in the current state.
    var cornerTop: CGFloat {
        switch state {
        case .compact: 6
        case .peek: 9
        case .expanded: 12
        }
    }

    var cornerBottom: CGFloat {
        let r = settings.roundness
        switch state {
        case .compact: return banner == nil ? min(r, 10) : min(r, 16)
        case .peek: return min(r, 18)
        case .expanded: return r
        }
    }

    /// What is actually painted: the body plus the flares either side.
    var drawnSize: CGSize {
        CGSize(width: size.width + cornerTop * 2, height: size.height)
    }

    // MARK: - State changes

    func hover(_ inside: Bool) {
        switch (state, inside) {
        case (.compact, true) where settings.hoverToPeek:
            set(.peek)
        case (.peek, false):
            set(.compact)
        case (.expanded, false):
            set(.compact)
        default:
            break
        }
    }

    static let tracing = UserDefaults.standard.bool(forKey: "IslandSelfTest")
    /// Who asked last — filled in by the controller when tracing.
    static var lastReason = ""

    func open(_ tab: IslandTab? = nil) {
        if let tab { select(tab) }
        set(.expanded)
    }

    func close() { set(.compact) }

    func select(_ new: IslandTab) {
        guard new != tab else { return }
        let all = IslandTab.allCases
        tabDirection = (all.firstIndex(of: new) ?? 0) > (all.firstIndex(of: tab) ?? 0) ? 1 : -1
        tab = new
        system.setVisible(state == .expanded && new == .system)
        claude.setVisible(state == .expanded && new == .system)
    }

    private func set(_ new: IslandState, _ why: String = #function) {
        guard new != state else { return }
        if Self.tracing { print("SELFTEST state \(state) → \(new) [\(why)] \(Self.lastReason)") }
        let opening = rank(new) > rank(state)
        withAnimation(IslandMotion.spring(opening: opening, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, style: settings.style)) {
            state = new
        }
        system.setVisible(new == .expanded && tab == .system)
        claude.setVisible(new == .expanded && tab == .system)
    }

    private func rank(_ s: IslandState) -> Int {
        switch s {
        case .compact: 0
        case .peek: 1
        case .expanded: 2
        }
    }

    // MARK: - Focus

    private func focusFinished(_ phase: FocusTimer.Phase) {
        if settings.haptics { Haptics.tap(strong: true) }
        NSSound(named: phase == .work ? "Glass" : "Hero")?.play()
        show(Banner(
            symbol: phase == .work ? "cup.and.saucer.fill" : "bolt.fill",
            text: phase == .work ? "Focus done — take a break" : "Break over — back to it"
        ))
    }

    func show(_ banner: Banner) {
        withAnimation(IslandMotion.spring(opening: true, reduceMotion: false, style: settings.style)) { self.banner = banner }
        let id = banner.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard self.banner?.id == id else { return }
            withAnimation(IslandMotion.spring(opening: false, reduceMotion: false)) { self.banner = nil }
        }
    }
}

struct Banner: Equatable, Identifiable {
    let id = UUID()
    var symbol: String
    var text: String
}

/// Where the notch is on this Mac, measured rather than assumed. A MacBook
/// with a notch reports it through the screen's safe area; anything else
/// (an external display, an Intel MacBook) gets a pill the height of the menu
/// bar so the island still has somewhere to live.
struct NotchGeometry: Equatable {
    var hasNotch: Bool
    var notchSize: CGSize
    var screenFrame: CGRect

    static let fallback = NotchGeometry(hasNotch: false, notchSize: CGSize(width: 190, height: 32), screenFrame: .zero)

    static func measure(_ screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            let width = screen.frame.width - left - right
            return NotchGeometry(hasNotch: true, notchSize: CGSize(width: width, height: top), screenFrame: screen.frame)
        }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(hasNotch: false, notchSize: CGSize(width: 190, height: menuBar), screenFrame: screen.frame)
    }

    /// The screen with a notch if there is one — that is where the island
    /// belongs — otherwise the one with the menu bar.
    static var preferredScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

enum IslandMotion {
    /// Opening carries a little bounce — the island "pops", like on iPhone.
    /// Closing is critically damped: settling back into the notch should
    /// never overshoot past it. Reduced motion swaps both for a short fade.
    /// The cartoon style is deliberately rubbery, both ways.
    static func spring(opening: Bool, reduceMotion: Bool, style: IslandStyle = .apple) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.18) }
        if style == .cartoon {
            return opening
                ? .spring(response: 0.5, dampingFraction: 0.58)
                : .spring(response: 0.38, dampingFraction: 0.8)
        }
        return opening
            ? .spring(response: 0.42, dampingFraction: 0.78)
            : .spring(response: 0.34, dampingFraction: 1.0)
    }
}

enum Haptics {
    static func tap(strong: Bool = false) {
        NSHapticFeedbackManager.defaultPerformer.perform(strong ? .levelChange : .alignment, performanceTime: .now)
    }
}
