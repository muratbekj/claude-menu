import AppKit

/// A pixel isometric cube, a homage to Cursor's logo. Its three faces are three shades
/// of one colour, so it still reads in a one-colour (template) menu bar image.
enum CursorMark {
    static let faces = [
        "....TTT....",
        "..TTTTTTT..",
        ".TTTTTTTTT.",
        "LTTTTTTTTTR",
        "LLLTTTTTRRR",
        "LLLLLTRRRRR",
        "LLLLLLRRRRR",
        "LLLLLLRRRRR",
        "LLLLLLRRRRR",
        ".LLLLLRRRR.",
        "..LLLLRRR..",
        "....LLR....",
    ]

    enum Style {
        case normal     // Premium models
        case hollowTop  // showing Cursor's own models: top face drawn as an outline
        case greyed     // both pools used up
    }

    private static let shade: [Character: CGFloat] = ["T": 1.0, "L": 0.72, "R": 0.42]
    private static let greyedFactor: CGFloat = 0.35

    private static let grid: [[Character]] = faces.map(Array.init)

    private static func face(_ x: Int, _ y: Int) -> Character {
        guard grid.indices.contains(y), grid[y].indices.contains(x) else { return "." }
        return grid[y][x]
    }

    /// Pixel coordinates (row 0 at the top) and alpha for each filled pixel.
    static func pixels(style: Style) -> [(x: Int, y: Int, alpha: CGFloat)] {
        var result: [(x: Int, y: Int, alpha: CGFloat)] = []
        for (y, row) in grid.enumerated() {
            for (x, ch) in row.enumerated() {
                guard var alpha = shade[ch] else { continue }
                if style == .hollowTop, ch == "T",
                   [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].allSatisfy({ face($0.0, $0.1) == "T" }) {
                    continue
                }
                if style == .greyed { alpha *= greyedFactor }
                result.append((x, y, alpha))
            }
        }
        return result
    }

    /// The colour at `shade` times its own opacity. Dynamic system colours are resolved for the
    /// current appearance first, so call this at draw time.
    static func shaded(_ color: NSColor, _ shade: CGFloat) -> NSColor {
        let base = color.usingColorSpace(.sRGB) ?? color
        return base.withAlphaComponent(base.alphaComponent * shade)
    }

    /// `height` is the drawn height in points; pixels are square.
    static func image(height: CGFloat, color: NSColor, style: Style) -> NSImage {
        let p = height / CGFloat(grid.count)
        let size = NSSize(width: ceil(p * CGFloat(grid[0].count)), height: height)
        let pixels = pixels(style: style)
        return NSImage(size: size, flipped: true) { _ in
            // One path per shade, filled once, so neighbouring pixels don't show anti-aliased seams.
            for alpha in Set(pixels.map(\.alpha)) {
                let path = NSBezierPath()
                for px in pixels where px.alpha == alpha {
                    path.appendRect(NSRect(x: CGFloat(px.x) * p, y: CGFloat(px.y) * p, width: p, height: p))
                }
                shaded(color, alpha).setFill()
                path.fill()
            }
            return true
        }
    }
}
