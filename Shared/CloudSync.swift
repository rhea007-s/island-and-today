import Combine
import Foundation
import Security

/// Keeps the task list the same on the iPhone and the Mac through Firestore's
/// REST API — no Firebase SDK, so no keychain-sharing entitlement or paid team.
///
/// Layout: `users/{uid}/tasks/{taskID}` = `{json, updatedAt, deleted, syncedAt}`.
/// `json` is the task exactly as tasks.json stores it, so a new field on
/// `DayTask` syncs without touching this file. `syncedAt` is stamped by the
/// server, which makes "what changed since I last looked" one cheap query
/// that does not trust either device's clock. Conflicts: newest `updatedAt`
/// wins. Deletions travel as tombstones (`deleted: true`).
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    enum Status: Equatable {
        case signedOut, idle, syncing
        case failed(String)
    }

    @Published private(set) var status: Status = .signedOut
    @Published private(set) var email: String?
    @Published private(set) var lastSync: Date?

    private var session: Session?
    private var idToken: String?
    private var idTokenExpiry = Date.distantPast
    private var pending: Task<Void, Never>?
    private var poller: Timer?

    private init() {
        session = SessionStore.load()
        email = session?.email
        status = session == nil ? .signedOut : .idle
    }

    var isSignedIn: Bool { session != nil }

    // MARK: - Starting

    /// Sync now, then every `interval` seconds while the app runs. The Mac has
    /// no "came to the foreground" moment worth trusting, so it polls; each
    /// poll is one small query that returns only what changed.
    func start(polling interval: TimeInterval? = nil) {
        sync()
        guard let interval, poller == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in CloudSync.shared.sync() }
        }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)
        poller = t
    }

    /// Any local change: push it shortly. Coalesces a burst of edits into one
    /// request. Safe to call from any process; without a session it does nothing.
    nonisolated static func localChanged() {
        Task { @MainActor in
            guard shared.isSignedIn else { return }
            shared.pending?.cancel()
            shared.pending = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                shared.sync()
            }
        }
    }

    // MARK: - Account

    func signIn(email: String, password: String, createAccount: Bool) async {
        status = .syncing
        do {
            let endpoint = createAccount ? "accounts:signUp" : "accounts:signInWithPassword"
            let reply = try await Self.postJSON(
                "https://identitytoolkit.googleapis.com/v1/\(endpoint)?key=\(FirebaseConfig.webAPIKey)",
                body: ["email": email, "password": password, "returnSecureToken": true]
            )
            guard let uid = reply["localId"] as? String,
                  let refresh = reply["refreshToken"] as? String,
                  let token = reply["idToken"] as? String
            else { throw SyncError.message("Unexpected reply from sign-in.") }
            let new = Session(uid: uid, email: reply["email"] as? String ?? email, refreshToken: refresh)
            SessionStore.save(new)
            session = new
            self.email = new.email
            idToken = token
            idTokenExpiry = Date().addingTimeInterval(Double(reply["expiresIn"] as? String ?? "3600").map { $0 - 120 } ?? 3000)
            // A new account (or a new device on an old one) starts from the
            // full picture: pull everything, then push everything local.
            SyncState.reset()
            status = .idle
            await run()
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    func signOut() {
        SessionStore.clear()
        SyncState.reset()
        session = nil
        email = nil
        idToken = nil
        status = .signedOut
    }

    // MARK: - Sync

    func sync() {
        guard isSignedIn, status != .syncing else { return }
        Task { await run() }
    }

    private func run() async {
        guard let session else { return }
        status = .syncing
        do {
            let token = try await validToken()
            var state = SyncState.load()
            try await pull(session: session, token: token, state: &state)
            try await push(session: session, token: token, state: &state)
            state.save()
            lastSync = Date()
            status = .idle
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    private var documentsRoot: String {
        "https://firestore.googleapis.com/v1/projects/\(FirebaseConfig.projectID)/databases/(default)/documents"
    }

    /// Everything stamped by the server since the last pull, merged into the
    /// store by newest `updatedAt`.
    private func pull(session: Session, token: String, state: inout SyncState) async throws {
        var query: [String: Any] = ["from": [["collectionId": "tasks"]]]
        if let cursor = state.cursor {
            query["where"] = ["fieldFilter": [
                "field": ["fieldPath": "syncedAt"],
                "op": "GREATER_THAN_OR_EQUAL",
                "value": ["timestampValue": Self.timestamp(cursor)],
            ]]
        }
        let rows = try await Self.request(
            "\(documentsRoot)/users/\(session.uid):runQuery",
            method: "POST", token: token, body: ["structuredQuery": query]
        ) as? [[String: Any]] ?? []

        var upserts: [DayTask] = []
        var deletions: [UUID: Date] = [:]
        var newest = state.cursor
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for row in rows {
            guard let doc = row["document"] as? [String: Any],
                  let fields = doc["fields"] as? [String: Any],
                  let name = doc["name"] as? String,
                  let id = UUID(uuidString: String(name.split(separator: "/").last ?? ""))
            else { continue }
            if let synced = Self.date(fields["syncedAt"]) { newest = max(newest ?? synced, synced) }
            let updated = Self.date(fields["updatedAt"]) ?? .distantPast
            state.known[id.uuidString] = updated.timeIntervalSince1970
            if (fields["deleted"] as? [String: Any])?["booleanValue"] as? Bool == true {
                deletions[id] = updated
            } else if let json = (fields["json"] as? [String: Any])?["stringValue"] as? String,
                      let task = try? decoder.decode(DayTask.self, from: Data(json.utf8)) {
                upserts.append(task)
            }
        }
        state.cursor = newest
        if !upserts.isEmpty || !deletions.isEmpty {
            TaskStore.shared.applyRemote(upserts: upserts, deletions: deletions)
        }
    }

    /// Local tasks newer than what the server last held, plus tombstones, in
    /// one atomic commit.
    private func push(session: Session, token: String, state: inout SyncState) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var writes: [[String: Any]] = []
        var sent: [String: Double] = [:]

        for task in TaskStore.read() {
            let stamp = task.updatedAt.timeIntervalSince1970
            if let known = state.known[task.id.uuidString], known >= stamp { continue }
            guard let data = try? encoder.encode(task), let json = String(data: data, encoding: .utf8) else { continue }
            writes.append(write(session, id: task.id.uuidString, json: json, updatedAt: task.updatedAt, deleted: false))
            sent[task.id.uuidString] = stamp
        }
        let now = Date()
        for id in state.pendingDeletes {
            writes.append(write(session, id: id, json: "", updatedAt: now, deleted: true))
            sent[id] = now.timeIntervalSince1970
        }
        guard !writes.isEmpty else { return }

        for chunk in stride(from: 0, to: writes.count, by: 400).map({ Array(writes[$0..<min($0 + 400, writes.count)]) }) {
            _ = try await Self.request("\(documentsRoot):commit", method: "POST", token: token, body: ["writes": chunk])
        }
        state.known.merge(sent) { _, new in new }
        state.pendingDeletes = []
    }

    private func write(_ session: Session, id: String, json: String, updatedAt: Date, deleted: Bool) -> [String: Any] {
        [
            "update": [
                "name": "projects/\(FirebaseConfig.projectID)/databases/(default)/documents/users/\(session.uid)/tasks/\(id)",
                "fields": [
                    "json": ["stringValue": json],
                    "updatedAt": ["timestampValue": Self.timestamp(updatedAt)],
                    "deleted": ["booleanValue": deleted],
                ],
            ],
            "updateTransforms": [["fieldPath": "syncedAt", "setToServerValue": "REQUEST_TIME"]],
        ]
    }

    // MARK: - Status for other devices

    #if os(macOS)
    private var lastClaude: [String: Any]?

    /// Copies the Mac's Claude Code usage to `users/{uid}/status/claude`, so
    /// the tablet island can show it — the tablet has no logs of its own.
    /// Only numbers and times; no prompts, paths or project names leave the Mac.
    func publishClaude(_ s: ClaudeUsage.Snapshot) {
        guard let session else { return }
        var fields: [String: Any] = [
            "dayTokens": ["integerValue": String(s.total)],
            "dayOutput": ["integerValue": String(s.output)],
            "dayReplies": ["integerValue": String(s.replies)],
            "sessionTokens": ["integerValue": String(s.sessionTokens)],
            "sessionReplies": ["integerValue": String(s.sessionReplies)],
            "model": ["stringValue": s.topModel ?? ""],
        ]
        if let start = s.sessionStart, let end = s.sessionEnd {
            fields["sessionStart"] = ["timestampValue": Self.timestamp(start)]
            fields["sessionEnd"] = ["timestampValue": Self.timestamp(end)]
        } else {
            fields["sessionStart"] = ["nullValue": NSNull()]
            fields["sessionEnd"] = ["nullValue": NSNull()]
        }
        // Unchanged numbers: skip the request.
        if let last = lastClaude, NSDictionary(dictionary: last).isEqual(to: fields) { return }
        lastClaude = fields
        var body = fields
        body["updatedAt"] = ["timestampValue": Self.timestamp(Date())]
        Task {
            do {
                let token = try await validToken()
                _ = try await Self.request(
                    "\(documentsRoot)/users/\(session.uid)/status/claude",
                    method: "PATCH", token: token, body: ["fields": body]
                )
            } catch {
                lastClaude = nil
            }
        }
    }
    #endif

    // MARK: - Tokens

    private func validToken() async throws -> String {
        if let idToken, Date() < idTokenExpiry { return idToken }
        guard let session else { throw SyncError.message("Not signed in.") }
        var request = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(FirebaseConfig.webAPIKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(session.refreshToken)".data(using: .utf8)
        let reply = try Self.decode(try await URLSession.shared.data(for: request)) as? [String: Any] ?? [:]
        guard let token = reply["id_token"] as? String else {
            signOut()
            throw SyncError.message("Signed out — please sign in again.")
        }
        if let refresh = reply["refresh_token"] as? String, refresh != session.refreshToken {
            var updated = session
            updated.refreshToken = refresh
            SessionStore.save(updated)
            self.session = updated
        }
        idToken = token
        idTokenExpiry = Date().addingTimeInterval((Double(reply["expires_in"] as? String ?? "3600") ?? 3600) - 120)
        return token
    }

    // MARK: - Deletions (any process)

    /// Called by the store when tasks are deleted, so the other device hears
    /// about it. Recorded even when signed out is harmless: sign-in resets it.
    nonisolated static func enqueueDeletion(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var state = SyncState.load()
        state.pendingDeletes.formUnion(ids.map(\.uuidString))
        state.save()
    }

    // MARK: - HTTP helpers

    enum SyncError: Error { case message(String) }

    private static func postJSON(_ url: String, body: [String: Any]) async throws -> [String: Any] {
        try await request(url, method: "POST", token: nil, body: body) as? [String: Any] ?? [:]
    }

    private static func request(_ url: String, method: String, token: String?, body: Any?) async throws -> Any {
        guard let u = URL(string: url) else { throw SyncError.message("Bad URL.") }
        var request = URLRequest(url: u)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try decode(try await URLSession.shared.data(for: request))
    }

    private static func decode(_ result: (Data, URLResponse)) throws -> Any {
        let (data, response) = result
        let json = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // Firebase errors: {"error": {"message": "EMAIL_EXISTS"}} — or an
            // array of them from Firestore.
            let first = (json as? [[String: Any]])?.first ?? json as? [String: Any]
            let message = (first?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(code)"
            throw SyncError.message(message)
        }
        return json
    }

    static func describe(_ error: Error) -> String {
        guard case let SyncError.message(raw) = error else { return error.localizedDescription }
        switch raw {
        case let m where m.hasPrefix("INVALID_LOGIN_CREDENTIALS"), let m where m.hasPrefix("INVALID_PASSWORD"),
             let m where m.hasPrefix("EMAIL_NOT_FOUND"):
            return "Wrong email or password."
        case let m where m.hasPrefix("EMAIL_EXISTS"): return "That email already has an account — sign in instead."
        case let m where m.hasPrefix("WEAK_PASSWORD"): return "Password needs at least 6 characters."
        case let m where m.hasPrefix("INVALID_EMAIL"): return "That email does not look right."
        case let m where m.hasPrefix("TOO_MANY_ATTEMPTS"): return "Too many tries — wait a minute."
        default: return raw
        }
    }

    // MARK: - Time

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func timestamp(_ date: Date) -> String { iso.string(from: date) }

    /// Firestore sends microseconds ("…:33.456789Z"); trim to milliseconds,
    /// which is all the formatter reads.
    static func date(_ value: Any?) -> Date? {
        guard var s = (value as? [String: Any])?["timestampValue"] as? String else { return nil }
        if let dot = s.firstIndex(of: "."), let z = s.firstIndex(of: "Z") {
            let fraction = s[s.index(after: dot)..<z]
            s = String(s[..<dot]) + "." + String((fraction + "000").prefix(3)) + "Z"
        } else {
            s = s.replacingOccurrences(of: "Z", with: ".000Z")
        }
        return iso.date(from: s)
    }
}

// MARK: - What this device knows about the server

struct SyncState: Codable {
    /// Newest server `syncedAt` already pulled.
    var cursor: Date?
    /// Task ID → the `updatedAt` the server holds, so unchanged tasks are not
    /// pushed again.
    var known: [String: Double] = [:]
    var pendingDeletes: Set<String> = []

    private static var url: URL { AppGroup.containerURL.appendingPathComponent("sync-state.json") }

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    static func reset() { SyncState().save() }
}

// MARK: - The signed-in account

struct Session: Codable {
    var uid: String
    var email: String
    /// Long-lived; trades for a one-hour ID token. The password is never kept.
    var refreshToken: String
}

enum SessionStore {
    #if os(macOS)
    // The Mac build is signed locally ("-"), so its identity changes with
    // every rebuild and the login keychain would ask for access each time.
    // A file only this user can read, like `gcloud` and `gh` use, instead.
    private static var url: URL { AppGroup.containerURL.appendingPathComponent("session.json") }

    static func load() -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
    #else
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.karaman.today.firebase",
        kSecAttrAccount as String: "session",
    ]

    static func load() -> Session? {
        var q = query
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
    #endif
}
