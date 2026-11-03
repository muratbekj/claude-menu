import Foundation
import Testing
@testable import ClaudeMenu

private let now = Date(timeIntervalSince1970: 1794230563 - 6 * 86400)  // 6 days before the fixture's cycle end
private let cycleEnd = Date(timeIntervalSince1970: 1794230563)
private let ok = (200, Data(cursorFixture.utf8))
private let rejected = (401, Data(#"{"code":"unauthenticated"}"#.utf8))

private func jwt(expiresIn seconds: TimeInterval) -> String {
    "h.\(base64url(#"{"exp":\#(Int(now.timeIntervalSince1970 + seconds))}"#)).s"
}
private let validA = jwt(expiresIn: 30 * 86400)
private let validB = jwt(expiresIn: 31 * 86400)
private let expired = jwt(expiresIn: -60)
private let editor = "cursor_editor_token"

/// Scripted stand-ins for the Keychain, the editor's database, and the network.
private final class Fake: @unchecked Sendable {
    /// Successive Keychain reads; the last entry repeats.
    var keychain: [() throws -> String?] = []
    var keychainReads = 0
    var editorToken: String?
    var respond: (String) throws -> (Int, Data) = { _ in ok }
    var sent: [String] = []
    var planRaw: String?
    var planCalls = 0

    var deps: CursorDeps {
        CursorDeps(
            keychainToken: { [self] in
                keychainReads += 1
                guard !keychain.isEmpty else { return nil }
                return try keychain[min(keychainReads, keychain.count) - 1]()
            },
            editorToken: { [self] in editorToken },
            send: { [self] token in
                sent.append(token)
                let (status, body) = try respond(token)
                return (status: status, body: body)
            },
            plan: { [self] _ in
                planCalls += 1
                return planRaw
            })
    }
}

@Test func okWithKeychainToken() async {
    let fake = Fake()
    fake.keychain = [{ validA }]
    let state = await CursorFetcher(deps: fake.deps).fetch(now: now)
    #expect(state.problem == nil)
    #expect(state.usage?.cycleEnd == cycleEnd)
    #expect(fake.sent == [validA])
}

@Test func cachesTokenAcrossFetches() async {
    let fake = Fake()
    fake.keychain = [{ validA }]
    let fetcher = CursorFetcher(deps: fake.deps)
    _ = await fetcher.fetch(now: now)
    _ = await fetcher.fetch(now: now)
    #expect(fake.keychainReads == 1)
    #expect(fake.sent == [validA, validA])
}

@Test func fallsBackToEditorOn401() async {
    let fake = Fake()
    fake.keychain = [{ validA }]
    fake.editorToken = editor
    fake.respond = { $0 == validA ? rejected : ok }
    let state = await CursorFetcher(deps: fake.deps).fetch(now: now)
    #expect(state.problem == nil)
    #expect(state.usage != nil)
    #expect(fake.sent == [validA, editor])
}

@Test func rereadsKeychainAfter401() async {
    let fake = Fake()
    fake.keychain = [{ validA }, { validB }]
    fake.editorToken = editor
    fake.respond = { $0 == validA ? rejected : ok }
    let state = await CursorFetcher(deps: fake.deps).fetch(now: now)
    #expect(state.problem == nil)
    #expect(fake.sent == [validA, validB])
}

@Test func loginExpiredWhenAllRejected() async {
    let fake = Fake()
    fake.keychain = [{ validA }]
    fake.editorToken = editor
    fake.respond = { _ in rejected }
    let state = await CursorFetcher(deps: fake.deps).fetch(now: now)
    #expect(state == CursorState(usage: nil, problem: .loginExpired))
}

@Test func skipsExpiredJWTWithoutRequest() async {
    let fake = Fake()
    fake.keychain = [{ expired }]
    let state = await CursorFetcher(deps: fake.deps).fetch(now: now)
    #expect(state == CursorState(usage: nil, problem: .loginExpired))
    #expect(fake.sent.isEmpty)
}

@Test func deniedKeychainNotRetried() async {
    let fake = Fake()
    fake.keychain = [{ throw KeychainError.denied }]
    let fetcher = CursorFetcher(deps: fake.deps)
    #expect(await fetcher.fetch(now: now) == CursorState())
    #expect(await fetcher.fetch(now: now) == CursorState())
    #expect(fake.keychainReads == 1)
}

@Test func hiddenWithNoTokens() async {
    let fake = Fake()
    #expect(await CursorFetcher(deps: fake.deps).fetch(now: now) == CursorState(usage: nil, problem: nil))
    #expect(fake.sent.isEmpty)
}

@Test func offlineKeepsLastUsage() async {
    let fake = Fake()
    fake.keychain = [{ validA }]
    let fetcher = CursorFetcher(deps: fake.deps)
    let first = await fetcher.fetch(now: now)
    fake.respond = { _ in throw URLError(.notConnectedToInternet) }
    let second = await fetcher.fetch(now: now.addingTimeInterval(300))
    #expect(second.problem == .offline)
    #expect(second.usage == first.usage)
    #expect(second.usage != nil)
}

@Test func recoversAfterOffline() async {
    let fake = Fake()
    fake.keychain = [{ validA }]
    fake.respond = { _ in throw URLError(.notConnectedToInternet) }
    let fetcher = CursorFetcher(deps: fake.deps)
    #expect(await fetcher.fetch(now: now) == CursorState(usage: nil, problem: .offline))
    fake.respond = { _ in ok }
    let state = await fetcher.fetch(now: now.addingTimeInterval(300))
    #expect(state.problem == nil)
    #expect(state.usage != nil)
}

@Test func unavailableOnBadBody() async {
    let fake = Fake()
    fake.keychain = [{ validA }]
    fake.respond = { _ in (200, Data("{}".utf8)) }
    let fetcher = CursorFetcher(deps: fake.deps)
    #expect(await fetcher.fetch(now: now) == CursorState(usage: nil, problem: .unavailable))
    fake.respond = { _ in (500, Data()) }
    #expect(await fetcher.fetch(now: now) == CursorState(usage: nil, problem: .unavailable))
}

@Test func dropsLastUsageAfterCycleEnd() async {
    let fake = Fake()
    fake.keychain = [{ validA }]
    let fetcher = CursorFetcher(deps: fake.deps)
    _ = await fetcher.fetch(now: now)
    fake.respond = { _ in throw URLError(.timedOut) }
    let state = await fetcher.fetch(now: cycleEnd.addingTimeInterval(1))
    #expect(state == CursorState(usage: nil, problem: .offline))
}

@Test func planFetchedOnceAndCarried() async {
    let fake = Fake()
    fake.keychain = [{ validA }]
    fake.planRaw = "pro_student"
    let fetcher = CursorFetcher(deps: fake.deps)
    #expect(await fetcher.fetch(now: now).usage?.plan == "Pro Student")
    #expect(await fetcher.fetch(now: now).usage?.plan == "Pro Student")
    #expect(fake.planCalls == 1)
}
