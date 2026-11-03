import Foundation
import Testing
@testable import ClaudeMenu

private let usage = CursorUsage(premiumPercent: 14.7, cursorModelsPercent: 0.8, totalPercent: 7.7,
                                cycleEnd: Date(timeIntervalSince1970: 1794230563), plan: nil, fetchedAt: Date())

@Test func cursorShownOnlyWithSomethingToSay() {
    #expect(CursorState().isShown == false)
    #expect(CursorState(usage: nil, problem: .offline).isShown == false)
    #expect(CursorState(usage: nil, problem: .loginExpired).isShown)
    #expect(CursorState(usage: nil, problem: .unavailable).isShown)
    #expect(CursorState(usage: usage, problem: nil).isShown)
}

@Test func panelTitleNamesCursorWhenShown() {
    #expect(PanelView.title(cursorShown: false) == "Claude Code")
    #expect(PanelView.title(cursorShown: true) == "Claude Code + Cursor")
}
