import Foundation
import Testing
@testable import ClaudeMenu

/// The response verified against a real account on 2026-11-03 (trimmed).
let cursorFixture = #"{"billingCycleStart":"1791552163000","billingCycleEnd":"1794230563000","planUsage":{"totalSpend":696,"includedSpend":696,"remaining":1304,"limit":2000,"autoPercentUsed":0.7555555555555555,"apiPercentUsed":14.71111111111111,"totalPercentUsed":7.733333333333333},"enabled":true}"#

func base64url(_ s: String) -> String {
    Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

@Test func decodesVerifiedResponse() throws {
    let u = try CursorUsage.decode(Data(cursorFixture.utf8), fetchedAt: Date(timeIntervalSince1970: 0))
    #expect(abs(u.premiumPercent - 14.7111) < 0.001)
    #expect(abs(u.cursorModelsPercent - 0.7556) < 0.001)
    #expect(abs(u.totalPercent - 7.7333) < 0.001)
    #expect(u.cycleEnd == Date(timeIntervalSince1970: 1794230563))
    #expect(u.fetchedAt == Date(timeIntervalSince1970: 0))
    #expect(u.plan == nil)
}

@Test func decodesNumericCycleEnd() throws {
    let json = cursorFixture.replacingOccurrences(of: #""billingCycleEnd":"1794230563000""#, with: #""billingCycleEnd":1794230563000"#)
    #expect(json != cursorFixture)
    let u = try CursorUsage.decode(Data(json.utf8), fetchedAt: Date())
    #expect(u.cycleEnd == Date(timeIntervalSince1970: 1794230563))
}

@Test func rejectsMissingPlanUsage() {
    #expect(throws: CursorDecodeError.self) {
        try CursorUsage.decode(Data(#"{"billingCycleEnd":"1794230563000"}"#.utf8), fetchedAt: Date())
    }
}

@Test func planDisplayName() {
    #expect(CursorUsage.planDisplayName("pro_student") == "Pro Student")
    #expect(CursorUsage.planDisplayName("pro") == "Pro")
}

@Test func jwtExpiry() {
    let token = "x.\(base64url(#"{"exp":1797093300}"#)).y"
    #expect(JWT.expiry(token) == Date(timeIntervalSince1970: 1797093300))
}

@Test func jwtExpiryNilForOpaqueToken() {
    #expect(JWT.expiry("cursor_abc") == nil)
    #expect(JWT.expiry("a.!!!.b") == nil)
    #expect(JWT.expiry("x.\(base64url(#"{"sub":"u"}"#)).y") == nil)
}

@Test func rejectsNonFiniteNumbers() {
    for bad in [#""apiPercentUsed":"Infinity""#, #""apiPercentUsed":"NaN""#] {
        let json = cursorFixture.replacingOccurrences(of: #""apiPercentUsed":14.71111111111111"#, with: bad)
        #expect(json != cursorFixture)
        #expect(throws: CursorDecodeError.self) { try CursorUsage.decode(Data(json.utf8), fetchedAt: Date()) }
    }
    let farEnd = cursorFixture.replacingOccurrences(of: #""billingCycleEnd":"1794230563000""#, with: #""billingCycleEnd":"1e300""#)
    #expect(throws: CursorDecodeError.self) { try CursorUsage.decode(Data(farEnd.utf8), fetchedAt: Date()) }
}

@Test func percentLeftClamps() {
    #expect(LimitRow.percentLeft(42) == 58)
    #expect(LimitRow.percentLeft(-3) == 100)
    #expect(LimitRow.percentLeft(112) == 0)
}

@Test func liveSessionNeverPersists() {
    let config = CursorDeps.session.configuration
    #expect(config.urlCache == nil)
    #expect(config.httpCookieStorage == nil)
    #expect(config.httpShouldSetCookies == false)
    #expect(config.urlCredentialStorage == nil)
}

@Test func redirectsAreRefused() async {
    let guardDelegate = NoRedirects()
    let response = HTTPURLResponse(url: URL(string: "https://api2.cursor.sh/x")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
    let next = await guardDelegate.urlSession(CursorDeps.session, task: CursorDeps.session.dataTask(with: URL(string: "https://api2.cursor.sh/x")!),
                                              willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "https://evil.example/")!))
    #expect(next == nil)
}
