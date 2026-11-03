import Foundation
import Security
import SQLite3

/// What the app knows about Cursor usage. Hidden (both nil) means "no Cursor here": show nothing.
struct CursorState: Equatable {
    var usage: CursorUsage?
    var problem: CursorProblem?
}

extension CursorState {
    /// Whether the panel has anything to show for Cursor. Users without a Cursor login see no Cursor UI.
    var isShown: Bool {
        usage != nil || problem == .loginExpired || problem == .unavailable
    }
}

enum CursorProblem: Equatable {
    case loginExpired
    case unavailable
    case offline
}

enum KeychainError: Error {
    case denied
}

/// The outside world the fetcher talks to, injectable for tests.
struct CursorDeps: Sendable {
    /// Cursor Agent's token. Nil if the item is missing; throws `KeychainError.denied` if the user said no.
    var keychainToken: @Sendable () throws -> String?
    /// The Cursor editor's saved token, if any.
    var editorToken: @Sendable () -> String?
    /// Asks Cursor for usage. Throws on transport errors.
    var send: @Sendable (_ token: String) async throws -> (status: Int, body: Data)
    /// The plan's raw membership type (e.g. "pro_student"), if Cursor tells us.
    var plan: @Sendable (_ token: String) async -> String?
}

/// Fetches Cursor usage with the login Cursor already saved on this Mac.
/// Tokens are only ever held in memory and only ever sent to Cursor. They are never refreshed or written.
actor CursorFetcher {
    private let deps: CursorDeps
    private var cachedToken: String?
    private var keychainDenied = false
    private var lastUsage: CursorUsage?
    private var plan: String?
    private var planFetched = false

    init(deps: CursorDeps) {
        self.deps = deps
    }

    private enum Attempt {
        case ok(CursorUsage, token: String)
        case rejected
        case failed(CursorProblem)
    }

    func fetch(now: Date) async -> CursorState {
        // Only Cursor Agent's own login being rejected means "run cursor-agent". A stale editor
        // login alone (no agent login, or Keychain access denied) isn't something to nag about.
        var agentLoginRejected = false

        switch await tryKeychain(now: now) {
        case .ok(let usage, let token)?: return await succeeded(usage, token: token)
        case .failed(let problem)?: return failed(problem, now: now)
        case .rejected?: agentLoginRejected = true
        case nil: break
        }

        if let token = deps.editorToken() {
            switch await attempt(token, now: now) {
            case .ok(let usage, let token): return await succeeded(usage, token: token)
            case .failed(let problem): return failed(problem, now: now)
            case .rejected: break
            }
        }

        if agentLoginRejected { return failed(.loginExpired, now: now) }
        lastUsage = nil
        return CursorState()
    }

    /// Tries the cached Keychain token; after a rejection, re-reads the Keychain once in case
    /// Cursor Agent has saved a fresh token since. Nil when there is no Keychain token at all.
    private func tryKeychain(now: Date) async -> Attempt? {
        // Cached as soon as it's read, and dropped only when Cursor rejects it, so network
        // trouble never causes another Keychain read (or another macOS prompt).
        if cachedToken == nil { cachedToken = readKeychain() }
        guard var current = cachedToken else { return nil }
        for pass in 0..<2 {
            let result = await attempt(current, now: now)
            guard case .rejected = result else { return result }
            cachedToken = nil
            guard pass == 0, let fresh = readKeychain(), fresh != current else { return .rejected }
            cachedToken = fresh
            current = fresh
        }
        return .rejected
    }

    private func readKeychain() -> String? {
        guard !keychainDenied else { return nil }
        do {
            return try deps.keychainToken()
        } catch {
            keychainDenied = true
            return nil
        }
    }

    private func attempt(_ token: String, now: Date) async -> Attempt {
        if let exp = JWT.expiry(token), exp <= now { return .rejected }
        let response: (status: Int, body: Data)
        do {
            response = try await deps.send(token)
        } catch {
            return .failed(.offline)
        }
        switch response.status {
        case 200:
            guard let usage = try? CursorUsage.decode(response.body, fetchedAt: now) else { return .failed(.unavailable) }
            return .ok(usage, token: token)
        case 401, 403:
            return .rejected
        default:
            return .failed(.unavailable)
        }
    }

    private func succeeded(_ usage: CursorUsage, token: String) async -> CursorState {
        if !planFetched {
            planFetched = true
            plan = await deps.plan(token).map(CursorUsage.planDisplayName)
        }
        var usage = usage
        usage.plan = plan
        lastUsage = usage
        return CursorState(usage: usage, problem: nil)
    }

    /// Keeps showing the last numbers, unless they belong to a billing cycle that has ended.
    private func failed(_ problem: CursorProblem, now: Date) -> CursorState {
        if let last = lastUsage, now >= last.cycleEnd { lastUsage = nil }
        return CursorState(usage: lastUsage, problem: problem)
    }
}

// MARK: - Live dependencies

/// Cursor's API doesn't redirect; refusing redirects keeps the token from following one to another host.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

extension CursorDeps {
    /// A private session with no disk cache, cookie store or credential store, so the token
    /// (which a cached request would archive) is never written to disk.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static let live = CursorDeps(
        keychainToken: {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "cursor-access-token",
                kSecAttrAccount as String: "cursor-user",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                throw KeychainError.denied
            default:
                return nil
            }
        },
        editorToken: {
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "select value from ItemTable where key = 'cursorAuth/accessToken'", -1, &stmt, nil) == SQLITE_OK
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
            let token = String(cString: text)
            return token.isEmpty ? nil : token
        },
        send: { token in
            var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.httpBody = Data("{}".utf8)
            let (data, response) = try await session.data(for: request)
            return (status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        },
        plan: { token in
            var request = URLRequest(url: URL(string: "https://api2.cursor.sh/auth/full_stripe_profile")!)
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["membershipType"] as? String, !type.isEmpty
            else { return nil }
            return type
        })
}
