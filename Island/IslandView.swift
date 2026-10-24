import SwiftUI

/// The notch outline: flush with the top of the screen, with the small
/// outward flares the real notch has where it meets the menu bar, and round
/// bottom corners. Both radii animate, so the island softens as it grows.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Content arriving inside the island reads as the black material resolving
/// into it — blur, scale and opacity together — not a flat fade.
private struct Materialize: ViewModifier {
    var hidden: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: hidden ? 6 : 0)
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.94 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static func materialize(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: Materialize(hidden: true), identity: Materialize(hidden: false))
    }
}

struct IslandView: View {
    @Bindable var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var radii: (top: CGFloat, bottom: CGFloat) { (model.cornerTop, model.cornerBottom) }

    var body: some View {
        let size = model.size
        let shape = NotchShape(top: radii.top, bottom: radii.bottom)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandSurface(
                    style: style,
                    shape: shape,
                    accent: model.settings.accent.color,
                    resting: model.state == .compact,
                    blendsWithNotch: model.geometry.hasNotch
                )

                content
                    .padding(.horizontal, radii.top)
                    .frame(width: size.width + radii.top * 2, height: size.height, alignment: .top)
                    .clipShape(shape)
            }
            .frame(width: size.width + radii.top * 2, height: size.height)
            .contentShape(shape)
            // Tap-to-open only while closed. Expanded, the gesture is switched
            // off for the island itself so it can never compete with the tab
            // buttons and rows inside it.
            .gesture(
                TapGesture().onEnded { model.open() },
                including: model.state == .expanded ? .subviews : .all
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .tint(model.settings.accent.color)
        .fontDesign(style == .cartoon ? .rounded : .default)
        .animation(.easeInOut(duration: 0.25), value: style)
    }

    private var style: IslandStyle { model.settings.style }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .compact:
            CompactIsland(model: model)
                .transition(.materialize(reduceMotion))
        case .peek:
            PeekIsland(model: model)
                .transition(.materialize(reduceMotion))
        case .expanded:
            ExpandedIsland(model: model)
                .transition(.materialize(reduceMotion))
        }
    }
}

// MARK: - Compact

/// Wings either side of the notch. The camera sits in the middle, so nothing
/// is ever drawn there — only in the two side slots.
struct CompactIsland: View {
    let model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leading.frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: model.baseSize.width)
                trailing.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: model.baseSize.height)

            if let banner = model.banner {
                Label(banner.text, systemImage: banner.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(height: 30)
                    .transition(.opacity)
            }
        }
        .opacity(model.showsWings ? 1 : 0)
    }

    @ViewBuilder private var leading: some View {
        switch model.activity {
        case .focus:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                FocusRing(progress: model.focus.progress(at: context.date), lineWidth: 2.5)
            }
            .frame(width: 16, height: 16)
        case .meeting(let event):
            MeetingWing(event: event, leading: true)
        case .music:
            // The cover is its own button: a tap opens the song in its player
            // instead of opening the island.
            Artwork(url: model.music.track?.artworkURL, size: 20)
                .contentShape(Rectangle())
                .onTapGesture { model.music.openSong() }
                .help("Open the song")
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.activity {
        case .focus:
            FocusClock(timer: model.focus, size: 13)
                .foregroundStyle(model.focus.phase == .work ? model.settings.accent.color : .green)
        case .meeting(let event):
            MeetingWing(event: event, leading: false)
        case .music:
            EqualizerBars(playing: model.music.isPlaying, color: model.settings.accent.color)
                .frame(width: 18, height: 12)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Peek

/// Hover state: the wings, plus one line answering "what's next?".
struct PeekIsland: View {
    let model: IslandModel
    @ObservedObject private var store = TaskStore.shared

    var body: some View {
        let snapshot = TaskStore.snapshot()
        VStack(spacing: 0) {
            CompactIsland(model: model)
                .frame(height: model.baseSize.height)

            HStack(spacing: 10) {
                if let event = model.calendar.soon() ?? model.calendar.upcoming().first {
                    RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3, height: 16)
                    Text(event.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(event.isNow(.now) ? "now" : event.start.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(event.color)
                } else {
                FocusRing(progress: snapshot.progress, lineWidth: 2.5)
                    .frame(width: 16, height: 16)
                if let next = snapshot.headline, !snapshot.allDone {
                    Text(next.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                } else {
                    Text(snapshot.isEmpty ? "Nothing planned today" : "All done today")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                }
                Spacer(minLength: 8)
                if !snapshot.isEmpty {
                    Text("\(snapshot.doneCount)/\(snapshot.total)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Expanded

struct ExpandedIsland: View {
    @Bindable var model: IslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach([IslandTab.today, .focus, .music]) { tabButton($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear.frame(width: model.baseSize.width)

                HStack(spacing: 4) {
                    ForEach([IslandTab.clipboard, .system]) { tabButton($0) }
                    IconButton(symbol: "gearshape", help: "Settings") {
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                        model.close()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: model.baseSize.height)

            ZStack {
                tabContent
                    .id(model.tab)
                    .transition(tabTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
        .foregroundStyle(.white)
    }

    private var tabTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let d = model.tabDirection
        return .asymmetric(
            insertion: .offset(x: 28 * d).combined(with: .materialize(false)),
            removal: .offset(x: -28 * d).combined(with: .opacity)
        )
    }

    @ViewBuilder private var tabContent: some View {
        switch model.tab {
        case .today: TodayTab(model: model)
        case .focus: FocusTab(model: model)
        case .music: MusicTab(model: model)
        case .clipboard: ClipboardTab(model: model)
        case .system: SystemTab(model: model)
        }
    }

    private func tabButton(_ tab: IslandTab) -> some View {
        let selected = model.tab == tab
        return Button {
            withAnimation(IslandMotion.spring(opening: true, reduceMotion: reduceMotion, style: model.settings.style)) { model.select(tab) }
        } label: {
            Image(systemName: tab.symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 24)
                .foregroundStyle(selected ? Color.black : .white.opacity(0.65))
                .background {
                    if selected {
                        Capsule().fill(model.settings.accent.color)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(tab.title)
    }
}

// MARK: - Small shared pieces

/// Feedback on press, not on release: shrinks the moment the button is down.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 1), value: configuration.isPressed)
    }
}

struct IconButton: View {
    var symbol: String
    var help: String
    var size: CGFloat = 13
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 24)
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.65))
                .background(Capsule().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct FocusRing: View {
    var progress: Double
    var lineWidth: CGFloat
    var color: Color? = nil

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: lineWidth)
            // No arc at all at zero: a round cap on a zero-length trim still
            // draws a dot, which reads as "already started".
            Circle()
                .trim(from: 0, to: min(1, progress))
                .stroke(color ?? Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(progress > 0 ? 1 : 0)
        }
    }
}

/// Three bars that dance while music plays and settle flat when it pauses.
///
/// Core Animation, not a SwiftUI TimelineView: the bounce runs in the window
/// server's render loop, so the app itself does no work per frame. The
/// TimelineView version cost a steady ~6% CPU for as long as music played.
struct EqualizerBars: NSViewRepresentable {
    var playing: Bool
    var color: Color

    func makeNSView(context: Context) -> BarsView { BarsView() }

    func updateNSView(_ view: BarsView, context: Context) {
        view.update(playing: playing, color: NSColor(color))
    }

    final class BarsView: NSView {
        private let bars = (0..<3).map { _ in CALayer() }
        private var playing = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for bar in bars {
                bar.anchorPoint = CGPoint(x: 0.5, y: 0)
                bar.cornerRadius = 1.5
                bar.transform = CATransform3DMakeScale(1, 0.2, 1)
                layer?.addSublayer(bar)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            let w: CGFloat = 3, gap: CGFloat = 2.5
            let total = w * 3 + gap * 2
            var x = (bounds.width - total) / 2
            for bar in bars {
                bar.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
                bar.position = CGPoint(x: x + w / 2, y: 0)
                x += w + gap
            }
        }

        func update(playing: Bool, color: NSColor) {
            bars.forEach { $0.backgroundColor = color.cgColor }
            guard playing != self.playing else { return }
            self.playing = playing
            let durations: [CFTimeInterval] = [0.42, 0.55, 0.37]
            for (i, bar) in bars.enumerated() {
                if playing {
                    let a = CABasicAnimation(keyPath: "transform.scale.y")
                    a.fromValue = 0.3
                    a.toValue = 1.0
                    a.duration = durations[i]
                    a.autoreverses = true
                    a.repeatCount = .infinity
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    a.beginTime = CACurrentMediaTime() + Double(i) * 0.11
                    bar.add(a, forKey: "bounce")
                } else {
                    // Settle from wherever the bar is right now, not from the top.
                    let current = bar.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat ?? 0.2
                    bar.removeAnimation(forKey: "bounce")
                    let settle = CABasicAnimation(keyPath: "transform.scale.y")
                    settle.fromValue = current
                    settle.toValue = 0.2
                    settle.duration = 0.25
                    settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    bar.transform = CATransform3DMakeScale(1, 0.2, 1)
                    bar.add(settle, forKey: "settle")
                }
            }
        }
    }
}

struct Artwork: View {
    var url: URL?
    var size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var placeholder: some View {
        LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white))
    }
}
