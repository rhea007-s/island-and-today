import Foundation

/// The single piece of configuration the app and the widget must agree on.
/// Change this in one place; both targets read it.
enum AppGroup {
    static let identifier = "group.com.karaman.today"

    /// URL scheme the widget uses to deep-link back into the app.
    static let urlScheme = "today"

    /// The deep links the widget can send. Both targets read these constants,
    /// so a typo cannot make one side silently disagree with the other.
    enum Route {
        static let today = "today"
        /// Open the app with the composer focused, ready for a new task.
        static let add = "add"
        /// Open the Calendar app (`?t=` seconds since 2001, Calendar's clock).
        static let calendar = "calendar"
        /// Open a video-call link (`?u=`) on the widget's behalf.
        static let join = "join"
    }

    static func url(_ route: String) -> URL? {
        URL(string: "\(urlScheme)://\(route)")
    }

    /// Shared container both processes can read and write.
    /// Falls back to the local documents directory so SwiftUI previews and
    /// unit tests keep working before the App Group capability is enabled.
    static var containerURL: URL {
        #if os(macOS)
        // The Mac island is unsandboxed and signed to run locally, without a
        // team. Touching ~/Library/Group Containers from such a build makes
        // macOS ask "access data from other apps" on every launch, so the Mac
        // keeps its list in its own Application Support folder instead.
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Island", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
        #else
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    static var storeURL: URL {
        containerURL.appendingPathComponent("tasks.json")
    }
}
