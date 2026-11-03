import Darwin
import Foundation

/// What a cursor-agent debug log says about its session, built up one line at a time.
///
/// Cursor Agent has no session state file like Claude Code's, but every running `cursor-agent`
/// writes a debug log with analytics events: `cli.request.create` when you send a prompt,
/// `cli.request.completed` when the reply ends, and `cli.request.user_input.requested` /
/// `.response` around an approval prompt. These are internal, so a Cursor update may rename
/// them; then Cursor sessions just stop showing.
struct CursorLogState: Equatable {
    var state: SessionState = .idle
    var since: Date = .distantPast
    var conversationId: String?

    mutating func apply(line: Substring) {
        guard let event = Self.field("eventName", in: line) else { return }
        switch event {
        case "cli.request.create":
            set(.busy, line)
            if let id = Self.field("conversationId", in: line) { conversationId = id }
        case "cli.request.user_input.requested":
            let reason = Self.field("type", in: line) == "approval"
                ? "\(Self.field("tool", in: line) ?? "tool") approval needed"
                : "input needed"
            set(.waiting(reason), line)
        case "cli.request.user_input.response":
            set(.busy, line)
        case "cli.request.completed":
            set(.idle, line)
        default:
            break
        }
    }

    private mutating func set(_ s: SessionState, _ line: Substring) {
        state = s
        since = Self.timestamp(line) ?? Date()
    }

    /// The string value of `"key":"value"` in a log line's JSON.
    private static func field(_ key: String, in line: Substring) -> String? {
        guard let r = line.range(of: "\"\(key)\":\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Lines start with `[2026-11-03T18:47:01.507Z]`.
    private static func timestamp(_ line: Substring) -> Date? {
        guard line.first == "[", let end = line.firstIndex(of: "]") else { return nil }
        return iso.date(from: String(line[line.index(after: line.startIndex)..<end]))
    }
}

enum CursorLog {
    /// `session-2026-11-03T18-46-26-120Z-25100-1.log` was written by process 25100.
    static func pid(fromFilename name: String) -> pid_t? {
        guard name.hasPrefix("session-"), name.hasSuffix(".log") else { return nil }
        let parts = name.dropLast(4).split(separator: "-")
        guard parts.count >= 3, let pid = Int32(parts[parts.count - 2]), pid > 0 else { return nil }
        return pid
    }

    /// Where cursor-agent writes its logs: `$TMPDIR/cursor-agent-logs-<uid>`.
    static var liveDir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cursor-agent-logs-\(getuid())")
    }

    static var liveChatsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/chats")
    }

    /// A process that is still running and is cursor-agent (its binary lives under `cursor-agent/`).
    static func isAgentProcess(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        return String(cString: buf).contains("cursor-agent")
    }
}

/// Lists the cursor-agent sessions that are working or waiting on you. Each log is read
/// incrementally: only what was appended since the last call, and only whole lines.
final class CursorSessionReader {
    private let logDir: URL
    private let chatsDir: URL
    private let isAlive: (pid_t) -> Bool

    private struct Tracked {
        var offset: UInt64 = 0
        var log = CursorLogState()
    }
    private var tracked: [URL: Tracked] = [:]
    private var metaCache: [String: (title: String?, cwd: String?)] = [:]

    init(logDir: URL = CursorLog.liveDir, chatsDir: URL = CursorLog.liveChatsDir,
         isAlive: @escaping (pid_t) -> Bool = CursorLog.isAgentProcess) {
        self.logDir = logDir
        self.chatsDir = chatsDir
        self.isAlive = isAlive
    }

    func sessions() -> [Session] {
        let files = (try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)) ?? []
        var live: [URL: Tracked] = [:]
        var out: [Session] = []
        for url in files {
            guard let pid = CursorLog.pid(fromFilename: url.lastPathComponent), isAlive(pid) else { continue }
            var t = tracked[url] ?? Tracked()
            read(url, into: &t)
            live[url] = t
            guard t.log.state != .idle else { continue }
            out.append(session(pid: pid, log: t.log))
        }
        tracked = live  // forget logs whose process has exited
        return out
    }

    private func read(_ url: URL, into t: inout Tracked) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return }
        if size < t.offset { t = Tracked() }  // the log was replaced
        guard size > t.offset else { return }
        try? h.seek(toOffset: t.offset)
        guard let data = try? h.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let whole = data[data.startIndex...lastNewline]
        t.offset += UInt64(whole.count)
        for line in String(decoding: whole, as: UTF8.self).split(separator: "\n") {
            t.log.apply(line: line)
        }
    }

    private func session(pid: pid_t, log: CursorLogState) -> Session {
        let meta = log.conversationId.map(meta(for:))
        let folder = meta?.cwd.map { ($0 as NSString).lastPathComponent } ?? "Cursor Agent"
        let title = meta?.title.flatMap { $0.isEmpty ? nil : $0 }
        return Session(id: "cursor-\(pid)", pid: pid, name: title ?? folder, folder: folder,
                       isBackground: false, state: log.state, since: log.since, context: nil, source: .cursor)
    }

    /// `~/.cursor/chats/<workspace hash>/<conversation id>/meta.json` holds the chat's title and folder.
    /// Cursor names a chat a little after it starts, so only a found title is cached.
    private func meta(for conversation: String) -> (title: String?, cwd: String?) {
        if let cached = metaCache[conversation] { return cached }
        let workspaces = (try? FileManager.default.contentsOfDirectory(at: chatsDir, includingPropertiesForKeys: nil)) ?? []
        for ws in workspaces {
            let url = ws.appendingPathComponent(conversation).appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: url),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let found = (title: d["title"] as? String, cwd: d["cwd"] as? String)
            if found.title != nil { metaCache[conversation] = found }
            return found
        }
        return (nil, nil)
    }
}
