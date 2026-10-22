import AppKit
import Darwin
import Foundation
import ServiceManagement

enum SessionState: Equatable {
    case waiting(String)
    case busy
    case idle
}

struct Session: Identifiable, Equatable {
    let id: String
    let pid: pid_t
    let name: String
    let folder: String
    let isBackground: Bool
    let state: SessionState
    let since: Date
    let context: Double?  // percent of context window used, 0...100
}

struct Limit: Equatable {
    let usedPercent: Double
    let resetsAt: Date
}

struct Usage: Equatable {
    let fiveHour: Limit?
    let sevenDay: Limit?
    let updatedAt: Date
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var usage: Usage?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    private let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private var statusDir: URL { claudeDir.appendingPathComponent("claude-menu/status") }
    private var transcriptCache: [URL: (mtime: Date, tokens: Double, model: String?)] = [:]
    private var timer: Timer?

    var waiting: [Session] { sessions.filter { if case .waiting = $0.state { return true } else { return false } } }
    var busy: [Session] { sessions.filter { $0.state == .busy } }
    var idle: [Session] { sessions.filter { $0.state == .idle } }

    /// Out of session or weekly usage until the window resets.
    var limitReached: Bool {
        [usage?.fiveHour, usage?.sevenDay].contains { ($0?.usedPercent ?? 0) >= 100 }
    }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let payloads = loadStatusPayloads()
        let newUsage = latestUsage(from: payloads)
        if newUsage != usage { usage = newUsage }

        var windowByModel: [String: Double] = [:]
        for p in payloads.values {
            if let model = (p.json["model"] as? [String: Any])?["id"] as? String,
               let size = (p.json["context_window"] as? [String: Any])?["context_window_size"] as? Double {
                windowByModel[model] = size
            }
        }

        let newSessions = loadSessions().map { raw in
            var s = raw
            let ctx = (payloads[s.id]?.json["context_window"] as? [String: Any])?["used_percentage"] as? Double
            s.context = ctx ?? transcriptContext(sessionId: s.id, cwd: s.cwd, windows: windowByModel)
            return s.session
        }
        .sorted { a, b in
            if a.state == .idle, b.state == .idle { return a.since > b.since }
            if case .waiting = a.state, case .waiting = b.state { return a.since < b.since }
            return a.since > b.since
        }
        // Only publish real changes so the menu bar icon and panel don't redraw every tick.
        if newSessions != sessions { sessions = newSessions }
    }

    // MARK: - Sessions (~/.claude/sessions/<pid>.json, written by Claude Code itself)

    private struct RawSession {
        let id: String
        let pid: pid_t
        let name: String
        let cwd: String
        let isBackground: Bool
        let state: SessionState
        let since: Date
        var context: Double?

        var session: Session {
            Session(id: id, pid: pid, name: name, folder: (cwd as NSString).lastPathComponent,
                    isBackground: isBackground, state: state, since: since, context: context)
        }
    }

    private func loadSessions() -> [RawSession] {
        let dir = claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let live: [[String: Any]] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = d["pid"] as? Int, d["spare"] == nil, isClaudeProcess(pid_t(pid))
            else { return nil }
            return d
        }
        // A session that handed its work to a running background job is shown via that job.
        let liveJobs = Set(live.compactMap { $0["jobId"] as? String })
        var seen = Set<String>()
        return live.compactMap { d in
            guard let pid = d["pid"] as? Int, let id = d["sessionId"] as? String, let cwd = d["cwd"] as? String,
                  !liveJobs.contains(d["parkedJobId"] as? String ?? ""), seen.insert(id).inserted
            else { return nil }

            let state: SessionState
            switch d["status"] as? String {
            case "waiting": state = .waiting(d["waitingFor"] as? String ?? "input needed")
            case "busy": state = .busy
            default: state = .idle
            }
            let ms = d["statusUpdatedAt"] as? Double ?? d["updatedAt"] as? Double ?? 0
            let folder = (cwd as NSString).lastPathComponent
            let name = (d["nameSource"] as? String) == "derived" ? folder : (d["name"] as? String ?? folder)
            return RawSession(id: id, pid: pid_t(pid), name: name, cwd: cwd,
                              isBackground: (d["kind"] as? String) == "bg", state: state,
                              since: Date(timeIntervalSince1970: ms / 1000))
        }
    }

    private func isClaudeProcess(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        return String(cString: buf).lowercased().contains("claude")
    }

    // MARK: - Statusline payloads (context %, rate limits)

    private func loadStatusPayloads() -> [String: (json: [String: Any], mtime: Date)] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: statusDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [String: (json: [String: Any], mtime: Date)] = [:]
        for url in files where url.pathExtension == "json" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if mtime < Date().addingTimeInterval(-7 * 86400) {
                try? fm.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            out[url.deletingPathExtension().lastPathComponent] = (json, mtime)
        }
        return out
    }

    private func latestUsage(from payloads: [String: (json: [String: Any], mtime: Date)]) -> Usage? {
        let reporting = payloads.values.filter { $0.json["rate_limits"] is [String: Any] }
        guard let newest = reporting.map(\.mtime).max() else { return nil }

        // Sessions report independently and idle ones go stale, so merge them: take the
        // latest window, and within it the highest usage (usage only grows within a window).
        func limit(_ key: String) -> Limit? {
            let candidates: [Limit] = reporting.compactMap {
                guard let l = ($0.json["rate_limits"] as? [String: Any])?[key] as? [String: Any],
                      let used = l["used_percentage"] as? Double,
                      let resets = l["resets_at"] as? Double
                else { return nil }
                return Limit(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
            }
            guard let best = candidates.max(by: { ($0.resetsAt, $0.usedPercent) < ($1.resetsAt, $1.usedPercent) })
            else { return nil }
            // A window that already reset is back to zero until Claude reports again.
            return best.resetsAt < Date() ? Limit(usedPercent: 0, resetsAt: best.resetsAt) : best
        }
        return Usage(fiveHour: limit("five_hour"), sevenDay: limit("seven_day"), updatedAt: newest)
    }

    // MARK: - Transcript fallback (background sessions don't run the statusline)

    private func transcriptContext(sessionId: String, cwd: String, windows: [String: Double]) -> Double? {
        let project = String(cwd.unicodeScalars.map { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) ? Character($0) : "-" })
        let url = claudeDir.appendingPathComponent("projects/\(project)/\(sessionId).jsonl")
        guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }

        let entry: (mtime: Date, tokens: Double, model: String?)
        if let cached = transcriptCache[url], cached.mtime == mtime {
            entry = cached
        } else {
            guard let found = lastUsage(in: url) else { return nil }
            entry = (mtime, found.tokens, found.model)
            transcriptCache[url] = entry
        }
        let window = entry.model.flatMap { windows[$0] } ?? (entry.tokens > 200_000 ? 1_000_000 : 200_000)
        return min(100, entry.tokens / window * 100)
    }

    private func lastUsage(in url: URL) -> (tokens: Double, model: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 1_000_000 ? size - 1_000_000 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() where line.contains("\"usage\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant", obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            let tokens = keys.reduce(0.0) { $0 + ((usage[$1] as? Double) ?? 0) }
            return (tokens, message["model"] as? String)
        }
        return nil
    }

    // MARK: - Actions

    /// Brings the terminal / editor window hosting the session to the front.
    func focus(_ session: Session) {
        var pid = session.pid
        for _ in 0..<24 {
            guard let parent = parentPID(of: pid), parent > 1 else { return }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                app.activate()
                return
            }
            pid = parent
        }
    }

    private func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ClaudeMenu: launch at login failed: \(error)")
        }
    }
}
