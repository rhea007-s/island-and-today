import SwiftUI
import Observation

/// What is playing in Music or Spotify, read and controlled over AppleScript.
///
/// Why AppleScript and not MediaRemote: MediaRemote is private, and since
/// macOS 15.4 it refuses third-party callers. Scripting is public, asks the
/// user once per player (System Settings → Privacy → Automation), and only
/// ever talks to a player that is already running — polling never launches one.
@MainActor
@Observable
final class NowPlaying {
    enum Player: String, CaseIterable {
        case spotify = "Spotify"
        case music = "Music"

        var bundleID: String {
            switch self {
            case .spotify: "com.spotify.client"
            case .music: "com.apple.Music"
            }
        }
    }

    struct Track: Equatable {
        var player: Player
        var title: String
        var artist: String
        var isPlaying: Bool
        var artworkURL: URL?
        var position: Double
        var duration: Double
        /// When `position` was read, so the progress bar can run between polls.
        var readAt: Date
    }

    private(set) var track: Track?
    /// The user said no to Automation for a player; the tab says how to undo it.
    private(set) var deniedPlayer: Player?
    /// Dominant color extracted from the album artwork, or a harmonic fallback.
    private(set) var dominantColor: Color?
    private var colorCache: [String: Color] = [:]

    var isPlaying: Bool { track?.isPlaying == true }

    private var poller: Timer?
    private let worker = ScriptWorker()
    /// Which players are open, kept current by launch/quit notifications.
    /// Asking NSWorkspace for every running app's bundle id on each poll was
    /// the app's single biggest idle cost (one LaunchServices round-trip per app).
    private(set) var runningPlayers: [Player] = []

    func start() {
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let id = app?.bundleIdentifier, Player.allCases.contains(where: { $0.bundleID == id }) else { return }
                MainActor.assumeIsolated { self?.refreshRunning() }
            }
        }
    }

    private func refreshRunning() {
        runningPlayers = Player.allCases.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
        if runningPlayers.isEmpty {
            track = nil
            dominantColor = nil
        }
        reschedule()
    }

    /// Fast while something plays (the progress bar and wings need it),
    /// slow while paused, and no timer at all when no player is open.
    private func reschedule() {
        let interval: TimeInterval? = runningPlayers.isEmpty ? nil : (isPlaying ? 1.5 : 4)
        guard poller?.timeInterval != interval else { return }
        poller?.invalidate()
        poller = nil
        guard let interval else { return }
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        poller = timer
    }

    private func poll() {
        let players = runningPlayers
        guard !players.isEmpty else { return }
        worker.read(players) { [weak self] result in
            guard let self else { return }
            switch result {
            case .track(let t):
                let trackChanged = self.track?.title != t.title || self.track?.artist != t.artist || self.track?.artworkURL != t.artworkURL
                if self.track != t { self.track = t }
                if trackChanged || self.dominantColor == nil { self.updateDominantColor(for: t) }
                self.deniedPlayer = nil
            case .nothing:
                if self.track != nil {
                    self.track = nil
                    self.dominantColor = nil
                }
            case .denied(let p):
                self.deniedPlayer = p
                self.track = nil
                self.dominantColor = nil
            }
            self.reschedule()
        }
    }

    func send(_ command: String) {
        guard let player = track?.player ?? runningPlayers.first else { return }
        worker.run("tell application \"\(player.rawValue)\" to \(command)") { [weak self] in
            self?.poll()
        }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func updateDominantColor(for track: Track?) {
        guard let track else {
            dominantColor = nil
            return
        }
        let cacheKey = track.artworkURL?.absoluteString ?? "\(track.artist)-\(track.title)"
        if let cached = colorCache[cacheKey] {
            if dominantColor != cached { dominantColor = cached }
            return
        }

        if let url = track.artworkURL {
            Task.detached(priority: .utility) { [weak self, url, cacheKey] in
                guard let data = try? Data(contentsOf: url),
                      let image = NSImage(data: data) else {
                    await MainActor.run { self?.applyFallbackColor(key: cacheKey, artist: track.artist, title: track.title) }
                    return
                }
                let color = Self.extractColor(from: image)
                await MainActor.run {
                    self?.colorCache[cacheKey] = color
                    if self?.track?.artworkURL == url {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            self?.dominantColor = color
                        }
                    }
                }
            }
        } else {
            applyFallbackColor(key: cacheKey, artist: track.artist, title: track.title)
        }
    }

    private func applyFallbackColor(key: String, artist: String, title: String) {
        let hash = abs((artist + title).hashValue)
        let hue = Double(hash % 360) / 360.0
        let color = Color(hue: hue, saturation: 0.7, brightness: 0.9)
        colorCache[key] = color
        withAnimation(.easeInOut(duration: 0.35)) {
            dominantColor = color
        }
    }

    nonisolated private static func extractColor(from image: NSImage) -> Color {
        let targetSize = NSSize(width: 16, height: 16)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 16 * 4,
            bitsPerPixel: 32
        ) else {
            return Color(red: 0.30, green: 0.62, blue: 1.00)
        }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: targetSize))
        NSGraphicsContext.restoreGraphicsState()

        var bestColor: NSColor?
        var maxScore: CGFloat = -1

        for y in 0..<16 {
            for x in 0..<16 {
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                let s = pixel.saturationComponent
                let b = pixel.brightnessComponent
                if b > 0.15 && b < 0.95 && s > 0.25 {
                    let score = s * 1.5 + b
                    if score > maxScore {
                        maxScore = score
                        bestColor = pixel
                    }
                }
            }
        }

        if let best = bestColor {
            let finalColor = NSColor(
                hue: best.hueComponent,
                saturation: min(1.0, max(0.55, best.saturationComponent * 1.2)),
                brightness: min(1.0, max(0.75, best.brightnessComponent * 1.1)),
                alpha: 1.0
            )
            return Color(nsColor: finalColor)
        }
        return Color(red: 0.30, green: 0.62, blue: 1.00)
    }

    func seek(to seconds: Double) {
        guard let player = track?.player ?? runningPlayers.first else { return }
        if var current = track {
            current.position = seconds
            current.readAt = Date()
            self.track = current
        }
        let posStr = String(format: "%.1f", seconds).replacingOccurrences(of: ",", with: ".")
        worker.run("tell application \"\(player.rawValue)\" to set player position to \(posStr)") { [weak self] in
            self?.poll()
        }
    }


    /// Brings the player forward on the song that is playing: Spotify opens
    /// the track's own page, Music scrolls its library to the track.
    func openSong() {
        guard let player = track?.player ?? runningPlayers.first else { return }
        let script: String
        switch player {
        case .spotify:
            script = """
            tell application "Spotify"
                set u to spotify url of current track
                activate
            end tell
            open location u
            """
        case .music:
            script = """
            tell application "Music"
                reveal current track
                activate
            end tell
            """
        }
        worker.run(script) {}
    }

    func open(_ player: Player) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

/// Runs every script on one background queue. NSAppleScript is not safe to
/// use from several threads at once; one serial queue keeps it on one, and
/// keeps a slow player from ever stalling an animation on the main thread.
private final class ScriptWorker: @unchecked Sendable {
    enum Result: Sendable {
        case track(NowPlaying.Track)
        case nothing
        case denied(NowPlaying.Player)
    }

    private let queue = DispatchQueue(label: "island.nowplaying", qos: .utility)
    /// Compiled once, run many times — compiling AppleScript source is the
    /// expensive half of every poll. Only touched on `queue`.
    private var compiled: [NowPlaying.Player: NSAppleScript] = [:]

    // Each field on its own line. Numbers go through `as string`, which uses
    // the system locale — a Turkish Mac writes "12,5" — so parsing below
    // accepts both separators.
    private static let source: [NowPlaying.Player: String] = [
        .spotify: """
        tell application "Spotify"
            set s to player state as string
            if s is "stopped" then return "stopped"
            set t to current track
            return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (artwork url of t) & linefeed & (player position as string) & linefeed & ((duration of t) / 1000 as string)
        end tell
        """,
        .music: """
        tell application "Music"
            set s to player state as string
            if s is "stopped" then return "stopped"
            set t to current track
            return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & "" & linefeed & (player position as string) & linefeed & (duration of t as string)
        end tell
        """,
    ]

    func read(_ players: [NowPlaying.Player], completion: @escaping @MainActor (Result) -> Void) {
        queue.async {
            var paused: NowPlaying.Track?
            var denied: NowPlaying.Player?
            for player in players {
                switch self.query(player) {
                case .track(let t) where t.isPlaying:
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(.track(t)) } }
                    return
                case .track(let t):
                    paused = paused ?? t
                case .denied(let p):
                    denied = p
                case .nothing:
                    break
                }
            }
            let result: Result = paused.map(Result.track) ?? denied.map(Result.denied) ?? .nothing
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    func run(_ script: String, then: @escaping @MainActor () -> Void) {
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        }
    }

    private func query(_ player: NowPlaying.Player) -> Result {
        guard let script = compiled[player] ?? Self.source[player].flatMap(NSAppleScript.init(source:)) else { return .nothing }
        if compiled[player] == nil {
            var compileError: NSDictionary?
            script.compileAndReturnError(&compileError)
            compiled[player] = script
        }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int {
            // -1743: the user has not allowed (or refused) Automation.
            return code == -1743 ? .denied(player) : .nothing
        }
        guard let text = output.stringValue, text != "stopped" else { return .nothing }
        let f = text.components(separatedBy: "\n")
        guard f.count >= 6 else { return .nothing }
        return .track(NowPlaying.Track(
            player: player,
            title: f[1],
            artist: f[2],
            isPlaying: f[0] == "playing",
            artworkURL: URL(string: f[3]).flatMap { $0.scheme == nil ? nil : $0 },
            position: Self.number(f[4]),
            duration: Self.number(f[5]),
            readAt: Date()
        ))
    }

    private static func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }
}

struct MusicTab: View {
    let model: IslandModel
    private var music: NowPlaying { model.music }

    var body: some View {
        if let track = music.track {
            playing(track)
        } else if let denied = music.deniedPlayer {
            message(
                "Island needs permission to control \(denied.rawValue)",
                detail: "System Settings → Privacy & Security → Automation → Island → turn on \(denied.rawValue)."
            ) {
                Button("Open Automation settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
                .buttonStyle(ChipStyle())
            }
        } else {
            message("Nothing playing", detail: "Start something in Music or Spotify and it shows up here and in the notch.") {
                HStack(spacing: 6) {
                    ForEach(NowPlaying.Player.allCases, id: \.self) { p in
                        Button("Open \(p.rawValue)") { music.open(p) }.buttonStyle(ChipStyle())
                    }
                }
            }
        }
    }

    private func playing(_ track: NowPlaying.Track) -> some View {
        HStack(spacing: 22) {
            Artwork(url: track.artworkURL, size: 150)
                .onTapGesture { model.music.openSong() }
                .help("Open this song in \(track.player.rawValue)")
                .shadow(color: (model.music.dominantColor ?? .black).opacity(model.music.dominantColor != nil ? 0.45 : 0.6), radius: 18, y: 8)
                .scaleEffect(track.isPlaying ? 1 : 0.92)
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: track.isPlaying)

            VStack(alignment: .leading, spacing: 6) {
                Text(track.title)
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(2)
                Text(track.artist)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Label(track.player.rawValue, systemImage: track.player == .spotify ? "dot.radiowaves.left.and.right" : "music.note")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))

                Spacer(minLength: 8)

                MusicScrubber(track: track, music: music, accent: model.music.dominantColor ?? model.settings.accent.color)

                HStack(spacing: 18) {
                    control("backward.fill", 16) { music.previous() }
                    control(track.isPlaying ? "pause.fill" : "play.fill", 24) { music.playPause() }
                    control("forward.fill", 16) { music.next() }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func control(_ symbol: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func clock(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    private func message<Extra: View>(_ title: String, detail: String, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            extra()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MusicScrubber: View {
    let track: NowPlaying.Track
    let music: NowPlaying
    let accent: Color

    @State private var isDragging = false
    @State private var dragPosition: Double = 0
    @State private var isHovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = (track.isPlaying && !isDragging) ? context.date.timeIntervalSince(track.readAt) : 0
            let current = isDragging ? dragPosition : min(track.duration, track.position + elapsed)
            let progress = track.duration > 0 ? max(0, min(1, current / track.duration)) : 0

            VStack(spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(isHovering || isDragging ? 0.22 : 0.12))
                            .frame(height: isHovering || isDragging ? 5 : 3.5)

                        Capsule()
                            .fill(accent)
                            .frame(width: max(0, geo.size.width * CGFloat(progress)), height: isHovering || isDragging ? 5 : 3.5)

                        if isHovering || isDragging {
                            Circle()
                                .fill(.white)
                                .frame(width: 10, height: 10)
                                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                                .offset(x: max(0, min(geo.size.width - 10, geo.size.width * CGFloat(progress) - 5)))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .frame(height: 12)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDragging = true
                                let clampedX = max(0, min(geo.size.width, value.location.x))
                                let newProgress = Double(clampedX / geo.size.width)
                                dragPosition = newProgress * track.duration
                            }
                            .onEnded { value in
                                let clampedX = max(0, min(geo.size.width, value.location.x))
                                let newProgress = Double(clampedX / geo.size.width)
                                let target = newProgress * track.duration
                                music.seek(to: target)
                                Haptics.tap()
                                isDragging = false
                            }
                    )
                }
                .frame(height: 12)
                .onHover { h in
                    withAnimation(.easeInOut(duration: 0.15)) { isHovering = h }
                }

                HStack {
                    Text(clock(current))
                    Spacer()
                    Text("-" + clock(max(0, track.duration - current)))
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(isDragging ? 0.85 : 0.5))
            }
        }
    }

    private func clock(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}
