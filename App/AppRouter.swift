import Combine   // ObservableObject / @Published — do not rely on Foundation re-exporting it
import Foundation
import UIKit

/// Turns an incoming widget deep link into a piece of UI intent.
///
/// The widget cannot focus a text field in another process, so it asks: the URL
/// carries the request, the app decides what that means.
final class AppRouter: ObservableObject {
    /// Set when the app should open with the composer already focused.
    @Published var wantsComposer = false

    @MainActor
    func handle(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case AppGroup.Route.add:
            wantsComposer = true
        case AppGroup.Route.calendar:
            // Widgets may only open their own app, so the calendar tap lands
            // here and is passed straight on to Calendar.
            let t = query.first { $0.name == "t" }?.value ?? "\(Int(Date().timeIntervalSinceReferenceDate))"
            if let target = URL(string: "calshow:\(t)") { UIApplication.shared.open(target) }
        case AppGroup.Route.join:
            if let link = query.first(where: { $0.name == "u" })?.value.flatMap(URL.init(string:)),
               link.scheme == "https" || link.scheme == "http" {
                UIApplication.shared.open(link)
            }
        default:
            break
        }
    }
}
