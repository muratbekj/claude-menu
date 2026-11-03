import AppKit
import Testing
@testable import ClaudeMenu

private func alpha(_ pixels: [(x: Int, y: Int, alpha: CGFloat)], _ x: Int, _ y: Int) -> CGFloat? {
    pixels.first { $0.x == x && $0.y == y }?.alpha
}

@Test func faceGridShape() {
    #expect(CursorMark.faces.count == 12)
    #expect(CursorMark.faces.allSatisfy { $0.count == 11 })
    #expect(CursorMark.faces[0] == "....TTT....")
    #expect(CursorMark.faces[11] == "....LLR....")
}

@Test func normalAlphas() {
    let px = CursorMark.pixels(style: .normal)
    #expect(alpha(px, 5, 0) == 1.0)
    #expect(alpha(px, 0, 4) == 0.72)
    #expect(alpha(px, 10, 4) == 0.42)
    #expect(px.count == CursorMark.faces.joined().filter { $0 != "." }.count)
}

@Test func hollowTopRemovesInterior() {
    let normal = CursorMark.pixels(style: .normal)
    let hollow = CursorMark.pixels(style: .hollowTop)
    #expect(alpha(hollow, 5, 0) != nil)
    #expect(alpha(hollow, 5, 2) == nil)
    let sides = { (px: [(x: Int, y: Int, alpha: CGFloat)]) in
        px.filter { CursorMark.faces[$0.y][CursorMark.faces[$0.y].index(CursorMark.faces[$0.y].startIndex, offsetBy: $0.x)] != "T" }
            .map { "\($0.x),\($0.y),\($0.alpha)" }
    }
    #expect(sides(hollow) == sides(normal))
}

@Test func greyedScalesAlpha() {
    let normal = CursorMark.pixels(style: .normal)
    let greyed = CursorMark.pixels(style: .greyed)
    #expect(greyed.count == normal.count)
    for (g, n) in zip(greyed, normal) {
        #expect(g.x == n.x && g.y == n.y)
        #expect(abs(g.alpha - n.alpha * 0.35) < 0.0001)
    }
}

@Test func shadeKeepsBaseColorAlpha() {
    let shaded = CursorMark.shaded(NSColor(white: 0, alpha: 0.5), 0.72)
    #expect(abs(shaded.alphaComponent - 0.36) < 0.0001)
    #expect(abs(CursorMark.shaded(.black, 0.42).alphaComponent - 0.42) < 0.0001)
}
