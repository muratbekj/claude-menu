import Foundation
import Testing
@testable import ClaudeMenu

private let end = Date(timeIntervalSince1970: 1794230563)  // Nov 9 2026 13:22 UTC
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .gmt
    c.locale = Locale(identifier: "en_US")
    return c
}()

private func usage(premium: Double, auto: Double) -> CursorUsage {
    CursorUsage(premiumPercent: premium, cursorModelsPercent: auto, totalPercent: 0,
                cycleEnd: end, plan: nil, fetchedAt: end.addingTimeInterval(-86400))
}
private let before = end.addingTimeInterval(-86400)

@Test func badgePremiumNormally() {
    #expect(CursorBadge.from(usage(premium: 14.7, auto: 0.76), now: before) == .premium(14.7))
}

@Test func badgeSwitchesWhenPremiumOut() {
    #expect(CursorBadge.from(usage(premium: 100, auto: 0.76), now: before) == .cursorModels(0.76))
}

@Test func badgeExhausted() {
    let badge = CursorBadge.from(usage(premium: 120, auto: 100), now: before)
    #expect(badge == .exhausted)
    #expect(badge?.displayPercent == 100)
}

@Test func badgeNilAfterCycleEnd() {
    #expect(CursorBadge.from(usage(premium: 14.7, auto: 0.76), now: end.addingTimeInterval(1)) == nil)
    #expect(CursorBadge.from(nil, now: before) == nil)
}

@Test func badgeClampsDisplay() {
    #expect(CursorBadge.premium(-3).displayPercent == 0)
    #expect(CursorBadge.premium(14.7).displayPercent == 15)
    #expect(CursorBadge.cursorModels(140).displayPercent == 100)
}

@Test func menuBarText() {
    #expect(MenuBarIcon.text(claudeUsed: 42, badge: .premium(14.7)) == "42/15")
    #expect(MenuBarIcon.text(claudeUsed: nil, badge: .premium(14.7)) == "–/15")
    #expect(MenuBarIcon.text(claudeUsed: 42, badge: nil) == "42%")
    #expect(MenuBarIcon.text(claudeUsed: nil, badge: nil) == nil)
    #expect(MenuBarIcon.text(claudeUsed: 42, badge: .exhausted) == "42/100")
}

@Test func cycleResetDays() {
    let now = end.addingTimeInterval(-(6 * 86400 + 7200))
    #expect(Format.cycleReset(end, now: now, calendar: utc) == "Resets Nov 9 · in 6 days")
}

@Test func cycleResetHoursAndSingulars() {
    #expect(Format.cycleReset(end, now: end.addingTimeInterval(-5 * 3600), calendar: utc) == "Resets Nov 9 · in 5 hours")
    #expect(Format.cycleReset(end, now: end.addingTimeInterval(-86400), calendar: utc) == "Resets Nov 9 · in 1 day")
    #expect(Format.cycleReset(end, now: end.addingTimeInterval(-3600), calendar: utc) == "Resets Nov 9 · in 1 hour")
    #expect(Format.cycleReset(end, now: end.addingTimeInterval(1), calendar: utc) == "Resets soon")
}
