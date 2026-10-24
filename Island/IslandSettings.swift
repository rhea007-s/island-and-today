import SwiftUI
import Observation
import ServiceManagement

enum IslandAccent: String, CaseIterable, Identifiable {
    case blue, green, orange, pink, purple, white

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: Color(red: 0.30, green: 0.62, blue: 1.00)
        case .green: Color(red: 0.30, green: 0.85, blue: 0.48)
        case .orange: Color(red: 1.00, green: 0.62, blue: 0.22)
        case .pink: Color(red: 1.00, green: 0.38, blue: 0.62)
        case .purple: Color(red: 0.70, green: 0.50, blue: 1.00)
        case .white: Color(white: 0.92)
        }
    }
}

/// The look of the island itself. Accent picks the colour; style picks the
/// material the island is made of.
enum IslandStyle: String, CaseIterable, Identifiable {
    /// Solid black, like the real Dynamic Island, with a hairline edge.
    case apple
    /// Translucent glass: the desktop shows through, frosted and tinted dark.
    case glass
    /// Ink fill, chunky white outline, a hard accent shadow and bouncy motion.
    case cartoon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple"
        case .glass: "Glass"
        case .cartoon: "Cartoon"
        }
    }
}

/// Every preference the island has, stored in UserDefaults. A class rather
/// than scattered @AppStorage so the model (not only views) can read them.
@MainActor
@Observable
final class IslandSettings {
    private let defaults = UserDefaults.standard

    var accent: IslandAccent { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    var style: IslandStyle { didSet { defaults.set(style.rawValue, forKey: "style") } }
    var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: "focusMinutes") } }
    var breakMinutes: Int { didSet { defaults.set(breakMinutes, forKey: "breakMinutes") } }
    var autoStartBreak: Bool { didSet { defaults.set(autoStartBreak, forKey: "autoStartBreak") } }
    var hoverToPeek: Bool { didSet { defaults.set(hoverToPeek, forKey: "hoverToPeek") } }
    var showMusicInCompact: Bool { didSet { defaults.set(showMusicInCompact, forKey: "showMusicInCompact") } }
    var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    var showCalendar: Bool { didSet { defaults.set(showCalendar, forKey: "showCalendar") } }
    /// How many minutes before an event the notch starts counting down to it.
    var remindMinutes: Int { didSet { defaults.set(remindMinutes, forKey: "remindMinutes") } }

    // Size — every length of the island, adjustable live from Settings.
    /// How far the side wings reach out from the notch while something is live.
    var wingWidth: Double { didSet { defaults.set(wingWidth, forKey: "wingWidth") } }
    var expandedWidth: Double { didSet { defaults.set(expandedWidth, forKey: "expandedWidth") } }
    /// Height of the open panel below the notch row.
    var expandedHeight: Double { didSet { defaults.set(expandedHeight, forKey: "expandedHeight") } }
    /// Displays without a notch: how long and tall the resting pill is.
    var pillWidth: Double { didSet { defaults.set(pillWidth, forKey: "pillWidth") } }
    var pillHeight: Double { didSet { defaults.set(pillHeight, forKey: "pillHeight") } }
    /// Bottom corner radius of the open island.
    var roundness: Double { didSet { defaults.set(roundness, forKey: "roundness") } }

    static let sizeDefaults: [String: Double] = [
        "wingWidth": 76, "expandedWidth": 560, "expandedHeight": 278,
        "pillWidth": 190, "pillHeight": 32, "roundness": 30,
    ]

    func resetSize() {
        let d = Self.sizeDefaults
        wingWidth = d["wingWidth"]!
        expandedWidth = d["expandedWidth"]!
        expandedHeight = d["expandedHeight"]!
        pillWidth = d["pillWidth"]!
        pillHeight = d["pillHeight"]!
        roundness = d["roundness"]!
    }

    init() {
        defaults.register(defaults: [
            "accent": IslandAccent.blue.rawValue,
            "style": IslandStyle.apple.rawValue,
            "focusMinutes": 25,
            "breakMinutes": 5,
            "autoStartBreak": true,
            "hoverToPeek": true,
            "showMusicInCompact": true,
            "clipboardEnabled": true,
            "haptics": true,
            "showCalendar": true,
            "remindMinutes": 10,
        ].merging(Self.sizeDefaults.mapValues { $0 as Any }) { a, _ in a })
        accent = IslandAccent(rawValue: defaults.string(forKey: "accent") ?? "") ?? .blue
        style = IslandStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .apple
        focusMinutes = defaults.integer(forKey: "focusMinutes")
        breakMinutes = defaults.integer(forKey: "breakMinutes")
        autoStartBreak = defaults.bool(forKey: "autoStartBreak")
        hoverToPeek = defaults.bool(forKey: "hoverToPeek")
        showMusicInCompact = defaults.bool(forKey: "showMusicInCompact")
        clipboardEnabled = defaults.bool(forKey: "clipboardEnabled")
        haptics = defaults.bool(forKey: "haptics")
        showCalendar = defaults.bool(forKey: "showCalendar")
        remindMinutes = defaults.integer(forKey: "remindMinutes")
        wingWidth = defaults.double(forKey: "wingWidth")
        expandedWidth = defaults.double(forKey: "expandedWidth")
        expandedHeight = defaults.double(forKey: "expandedHeight")
        pillWidth = defaults.double(forKey: "pillWidth")
        pillHeight = defaults.double(forKey: "pillHeight")
        roundness = defaults.double(forKey: "roundness")
    }

    /// Read from the system each time: the user can also flip this in
    /// System Settings → General → Login Items, and that must win.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Island: login item change failed: \(error.localizedDescription)")
            }
        }
    }
}
