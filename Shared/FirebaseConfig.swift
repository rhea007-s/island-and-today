import Foundation

/// Firebase project "notch" — used to sync tasks between the iPhone app and
/// the Mac island over Firestore's REST API (no Firebase SDK).
///
/// The Web API key is not a secret: it identifies the project to Google and
/// ships inside every Firebase client. What protects the data is Auth plus
/// the Firestore security rules (each user reads and writes only their own
/// `users/{uid}/…`). Never put a service-account key here.
enum FirebaseConfig {
    static let projectID = "notch-beda7"
    /// Lives in Shared/FirebaseKey.swift, which git ignores; copy
    /// Config/FirebaseKey.swift.example there and fill in your own key.
    static let webAPIKey = FirebaseKey.web
}
