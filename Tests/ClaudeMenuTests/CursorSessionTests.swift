import Foundation
import Testing
@testable import ClaudeMenu

// Lines as cursor-agent 2026.10.22 writes them to its debug log (trimmed).
private let created = #"[2026-11-03T18:47:01.507Z] analytics.track {"eventName":"cli.request.create","props":{"length":48,"model":"gpt-5.3-codex","mode":"default","invocationID":"e713","conversationId":"40e230cc-2eb3-411d-8e1b-25e0288f418c"}}"#
private let toolUsed = #"[2026-11-03T18:47:05.000Z] analytics.track {"eventName":"cli.request.tools.used","props":{"tool":"shellToolCall","count":1}}"#
private let approvalAsked = #"[2026-11-03T18:47:14.139Z] analytics.track {"eventName":"cli.request.user_input.requested","props":{"tool":"shell","type":"approval"}}"#
private let approvalAnswered = #"[2026-11-03T18:47:22.242Z] analytics.track {"eventName":"cli.request.user_input.response","props":{"tool":"shell","response":"approved"}}"#
private let completed = #"[2026-11-03T18:48:22.124Z] analytics.track {"eventName":"cli.request.completed","props":{"end_reason":"success","invocationID":"e713","conversationId":"40e230cc-2eb3-411d-8e1b-25e0288f418c"}}"#
private let noise = #"[2026-11-03T18:48:25.126Z] privacy.refresh.start {"isStale":false,"sampleEvery":10}"#

private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: iso)!
}

private func state(after lines: [String]) -> CursorLogState {
    var s = CursorLogState()
    for l in lines { s.apply(line: Substring(l)) }
    return s
}

@Test func freshLogIsIdle() {
    #expect(state(after: [noise]).state == .idle)
}

@Test func promptSentMeansWorking() {
    let s = state(after: [created, toolUsed])
    #expect(s.state == .busy)
    #expect(s.since == date("2026-11-03T18:47:01.507Z"))
    #expect(s.conversationId == "40e230cc-2eb3-411d-8e1b-25e0288f418c")
}

@Test func approvalRequestMeansWaiting() {
    let s = state(after: [created, approvalAsked])
    #expect(s.state == .waiting("shell approval needed"))
    #expect(s.since == date("2026-11-03T18:47:14.139Z"))
}

@Test func otherInputRequestIsGenericWaiting() {
    let asked = #"[2026-11-03T18:47:14.139Z] analytics.track {"eventName":"cli.request.user_input.requested","props":{"tool":"ask","type":"question"}}"#
    #expect(state(after: [created, asked]).state == .waiting("input needed"))
}

@Test func answeringApprovalGoesBackToWorking() {
    let s = state(after: [created, approvalAsked, approvalAnswered])
    #expect(s.state == .busy)
    #expect(s.since == date("2026-11-03T18:47:22.242Z"))
}

@Test func finishedReplyIsIdle() {
    #expect(state(after: [created, approvalAsked, approvalAnswered, completed, noise]).state == .idle)
}

@Test func secondPromptWorksAgain() {
    let again = created.replacingOccurrences(of: "18:47:01.507Z", with: "18:48:41.218Z")
    let s = state(after: [created, completed, again])
    #expect(s.state == .busy)
    #expect(s.since == date("2026-11-03T18:48:41.218Z"))
}

@Test func pidFromLogFilename() {
    #expect(CursorLog.pid(fromFilename: "session-2026-11-03T18-46-26-120Z-25100-1.log") == 25100)
    #expect(CursorLog.pid(fromFilename: "latest.log") == nil)
    #expect(CursorLog.pid(fromFilename: "session-2026-11-03T18-46-26-120Z-x-1.log") == nil)
}

// MARK: - Reading the log folder

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-sessions-\(UUID().uuidString)")
    var logs: URL { root.appendingPathComponent("logs") }
    var chats: URL { root.appendingPathComponent("chats") }

    init() throws {
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    }

    func log(pid: Int32) -> URL { logs.appendingPathComponent("session-2026-11-03T18-46-26-120Z-\(pid)-1.log") }

    func write(pid: Int32, _ lines: [String], terminated: Bool = true) throws {
        try (lines.joined(separator: "\n") + (terminated ? "\n" : "")).write(to: log(pid: pid), atomically: false, encoding: .utf8)
    }

    func append(pid: Int32, _ text: String) throws {
        let h = try FileHandle(forWritingTo: log(pid: pid))
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    func meta(conversation: String, _ json: String) throws {
        let dir = chats.appendingPathComponent("55925a4117a41e88a47b8b1f227c1704/\(conversation)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
    }

    func reader(alive: Set<Int32>) -> CursorSessionReader {
        CursorSessionReader(logDir: logs, chatsDir: chats, isAlive: { alive.contains($0) })
    }
}

private let conversation = "40e230cc-2eb3-411d-8e1b-25e0288f418c"

@Test func readerListsWorkingSessionWithChatTitle() throws {
    let f = try Fixture()
    try f.write(pid: 25100, [noise, created, toolUsed])
    try f.meta(conversation: conversation, #"{"title":"Fix login bug","cwd":"/Users/me/code/demo-app"}"#)
    let sessions = f.reader(alive: [25100]).sessions()
    #expect(sessions.count == 1)
    let s = try #require(sessions.first)
    #expect(s.pid == 25100)
    #expect(s.name == "Fix login bug")
    #expect(s.folder == "demo-app")
    #expect(s.state == .busy)
    #expect(s.source == .cursor)
    #expect(s.context == nil)
}

@Test func readerFallsBackToFolderName() throws {
    let f = try Fixture()
    try f.write(pid: 25100, [created])
    try f.meta(conversation: conversation, #"{"cwd":"/Users/me/code/sample"}"#)
    #expect(f.reader(alive: [25100]).sessions().first?.name == "sample")
}

@Test func readerFallsBackToCursorWithoutMeta() throws {
    let f = try Fixture()
    try f.write(pid: 25100, [created])
    let s = try #require(f.reader(alive: [25100]).sessions().first)
    #expect(s.name == "Cursor Agent")
    #expect(s.folder == "Cursor Agent")
}

@Test func readerSkipsIdleAndExitedSessions() throws {
    let f = try Fixture()
    try f.write(pid: 1, [created, completed])  // idle
    try f.write(pid: 2, [created])             // working, but its process has exited
    try f.write(pid: 3, [noise])               // never prompted
    #expect(f.reader(alive: [1, 3]).sessions().isEmpty)
}

@Test func readerPicksUpAppendedLines() throws {
    let f = try Fixture()
    try f.write(pid: 25100, [created])
    let r = f.reader(alive: [25100])
    #expect(r.sessions().first?.state == .busy)
    try f.append(pid: 25100, approvalAsked + "\n")
    #expect(r.sessions().first?.state == .waiting("shell approval needed"))
    try f.append(pid: 25100, approvalAnswered + "\n" + completed + "\n")
    #expect(r.sessions().isEmpty)
}

@Test func readerWaitsForWholeLines() throws {
    let f = try Fixture()
    try f.write(pid: 25100, [created])
    let r = f.reader(alive: [25100])
    #expect(r.sessions().first?.state == .busy)
    // Half an approval line, then the rest of it on the next tick.
    let cut = approvalAsked.index(approvalAsked.startIndex, offsetBy: 60)
    try f.append(pid: 25100, String(approvalAsked[..<cut]))
    #expect(r.sessions().first?.state == .busy)
    try f.append(pid: 25100, String(approvalAsked[cut...]) + "\n")
    #expect(r.sessions().first?.state == .waiting("shell approval needed"))
}

@Test func readerStartsOverWhenLogShrinks() throws {
    let f = try Fixture()
    try f.write(pid: 25100, [created, completed, noise, noise])
    let r = f.reader(alive: [25100])
    #expect(r.sessions().isEmpty)
    try f.write(pid: 25100, [created])  // replaced by a shorter log
    #expect(r.sessions().first?.state == .busy)
}

@Test func readerHandlesMissingLogFolder() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
    let r = CursorSessionReader(logDir: missing, chatsDir: missing, isAlive: { _ in true })
    #expect(r.sessions().isEmpty)
}
