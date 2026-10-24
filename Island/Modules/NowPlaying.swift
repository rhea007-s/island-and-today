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
        if runningPlayers.isEmpty { track = nil }
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
                if self.track != t { self.track = t }
                self.deniedPlayer = nil
            case .nothing:
                if self.track != nil { self.track = nil }
            case .denied(let p):
                self.deniedPlayer = p
                self.track = nil
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
                .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
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

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = track.isPlaying ? context.date.timeIntervalSince(track.readAt) : 0
                    let position = min(track.duration, track.position + elapsed)
                    VStack(spacing: 4) {
                        ProgressView(value: track.duration > 0 ? position / track.duration : 0)
                            .progressViewStyle(.linear)
                        HStack {
                            Text(clock(position))
                            Spacer()
                            Text("-" + clock(max(0, track.duration - position)))
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                    }
                }

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
