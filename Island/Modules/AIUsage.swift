import SwiftUI
import Observation

/// Today's Claude Code usage, read from the logs Claude Code already keeps in
/// ~/.claude/projects. No account, no key, nothing sent anywhere.
///
/// Read only while the System tab is open, and incrementally: each log is
/// remembered by how far it has been read, so a refresh costs the new lines,
/// not the whole folder.
@MainActor
@Observable
final class ClaudeUsage {
    struct Snapshot: Equatable {
        var input = 0          // fresh input + cache writes
        var cacheRead = 0
        var output = 0
        var replies = 0
        var hourly = [Int](repeating: 0, count: 24)
        var topModel: String?
        /// The current 5-hour session: it opens with the first message after
        /// the last one closed (on the hour, the way Claude counts it) and
        /// resets five hours later. `nil` when no session is running.
        var sessionStart: Date?
        var sessionTokens = 0
        var sessionReplies = 0

        var total: Int { input + cacheRead + output }
        var sessionEnd: Date? { sessionStart?.addingTimeInterval(ClaudeUsage.sessionLength) }

        func isLive(at now: Date) -> Bool { sessionEnd.map { now < $0 } ?? false }
    }

    nonisolated static let sessionLength: TimeInterval = 5 * 3600

    private(set) var today = Snapshot()
    private(set) var available = FileManager.default.fileExists(atPath: UsageScanner.root.path)

    private let scanner = UsageScanner()
    private var timer: Timer?

    /// Slow background refresh while the System tab is closed, so the
    /// session countdown and the copy published for the tablet stay current.
    private var background: Timer?

    func startBackground() {
        guard available, background == nil else { return }
        refresh()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.timer == nil { self?.refresh() } }
        }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        background = t
    }

    func setVisible(_ visible: Bool) {
        if visible, timer == nil, available {
            refresh()
            let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !visible {
            timer?.invalidate()
            timer = nil
        }
    }

    private func refresh() {
        Task {
            let fresh = await scanner.scan()
            if fresh != today { withAnimation(.spring(response: 0.4, dampingFraction: 1)) { today = fresh } }
            CloudSync.shared.publishClaude(fresh)
        }
    }
}

/// Off the main thread: file reading and JSON parsing.
actor UsageScanner {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    private struct Usage { var input: Int; var cacheRead: Int; var output: Int; var date: Date; var model: String }

    private var offsets: [String: UInt64] = [:]
    /// Keyed by message id: Claude Code writes one line per content block,
    /// each repeating the reply's usage, so the last line of a reply wins.
    private var replies: [String: Usage] = [:]

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func scan() -> ClaudeUsage.Snapshot {
        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.startOfDay(for: now)
        // A session can start before midnight, so read back far enough to
        // see where the current one began, not just today.
        let since = min(dayStart, now.addingTimeInterval(-2 * ClaudeUsage.sessionLength))
        replies = replies.filter { $0.value.date >= since }

        let fm = FileManager.default
        guard let walker = fm.enumerator(at: Self.root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return ClaudeUsage.Snapshot()
        }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, modified >= since,
                  let size = values.fileSize
            else { continue }
            var offset = offsets[url.path] ?? 0
            if UInt64(size) < offset { offset = 0 }
            guard UInt64(size) > offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd() else { continue }
            // Only whole lines; a line still being written is read next time.
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let complete = data[data.startIndex...lastNewline]
            offsets[url.path] = offset + UInt64(complete.count)
            for line in complete.split(separator: UInt8(ascii: "\n")) {
                parse(line, since: since)
            }
        }

        var snap = ClaudeUsage.Snapshot()
        var byModel: [String: Int] = [:]
        var todayCount = 0
        for u in replies.values where u.date >= dayStart {
            snap.input += u.input
            snap.cacheRead += u.cacheRead
            snap.output += u.output
            snap.hourly[cal.component(.hour, from: u.date)] += u.input + u.output
            byModel[u.model, default: 0] += u.output
            todayCount += 1
        }
        snap.replies = todayCount
        snap.topModel = byModel.max { $0.value < $1.value }?.key

        // Walk the replies in time order, opening a new 5-hour block whenever
        // one arrives after the previous block ran out.
        var start: Date?
        var tokens = 0, count = 0
        for u in replies.values.sorted(by: { $0.date < $1.date }) {
            if start == nil || u.date >= start!.addingTimeInterval(ClaudeUsage.sessionLength) {
                start = cal.dateInterval(of: .hour, for: u.date)?.start ?? u.date
                tokens = 0
                count = 0
            }
            tokens += u.input + u.output
            count += 1
        }
        if let start, now < start.addingTimeInterval(ClaudeUsage.sessionLength) {
            snap.sessionStart = start
            snap.sessionTokens = tokens
            snap.sessionReplies = count
        }
        return snap
    }

    private func parse(_ line: Data.SubSequence, since: Date) {
        // Cheap check before paying for JSON: most lines carry no usage.
        guard line.count > 40, line.firstRange(of: Data("\"usage\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let date = Self.iso.date(from: stamp), date >= since
        else { return }
        let id = message["id"] as? String ?? (object["requestId"] as? String ?? UUID().uuidString)
        func n(_ k: String) -> Int { usage[k] as? Int ?? 0 }
        replies[id] = Usage(
            input: n("input_tokens") + n("cache_creation_input_tokens"),
            cacheRead: n("cache_read_input_tokens"),
            output: n("output_tokens"),
            date: date,
            model: (message["model"] as? String ?? "claude").replacingOccurrences(of: "claude-", with: "")
        )
    }
}

/// The System tab's fourth tile.
struct ClaudeTile: View {
    let usage: ClaudeUsage
    let accent: Color

    var body: some View {
        let s = usage.today
        VStack(alignment: .leading, spacing: 6) {
            Text("CLAUDE CODE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
            Text(Self.compact(s.total))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(s.total)))
            HourBars(values: s.hourly, color: accent)
                .frame(height: 18)
            Text("\(Self.compact(s.output)) out · \(s.replies) replies")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            SessionLine(snapshot: s, accent: accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
        .help("Tokens Claude Code used today, read from ~/.claude/projects")
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...: String(format: "%.0fK", Double(n) / 1_000)
        case 1_000...: String(format: "%.1fK", Double(n) / 1_000)
        default: "\(n)"
        }
    }
}

/// "Session · resets in 2h 14m", with a bar for how much of the five hours
/// has gone. Ticks once a minute on its own.
struct SessionLine: View {
    let snapshot: ClaudeUsage.Snapshot
    let accent: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            if let start = snapshot.sessionStart, let end = snapshot.sessionEnd, now < end {
                let elapsed = now.timeIntervalSince(start) / ClaudeUsage.sessionLength
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Label(Self.remaining(end.timeIntervalSince(now)), systemImage: "arrow.clockwise")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .help("Time until this Claude session resets")
                        Spacer(minLength: 2)
                        Text(end, format: .dateTime.hour().minute())
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    ProgressView(value: min(1, max(0, elapsed)))
                        .tint(accent)
                        .controlSize(.mini)
                    Text("\(ClaudeTile.compact(snapshot.sessionTokens)) this session · \(snapshot.sessionReplies) replies")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            } else {
                Text("No session running — the next message starts one")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        let m = max(0, Int(seconds / 60))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

/// 24 thin bars, midnight to midnight; the current hour is brightest.
private struct HourBars: View {
    let values: [Int]
    let color: Color

    var body: some View {
        let peak = max(1, values.max() ?? 1)
        let hour = Calendar.current.component(.hour, from: Date())
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(values.indices, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(i == hour ? 1 : 0.55))
                    .frame(height: max(2, 18 * CGFloat(values[i]) / CGFloat(peak)))
            }
        }
    }
}
