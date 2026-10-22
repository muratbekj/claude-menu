import AppKit
import SwiftUI

@main
struct ClaudeMenuApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar icon

struct MenuBarLabel: View {
    @ObservedObject var store: Store
    @ObservedObject private var waver = Waver.shared

    init(store: Store) {
        self.store = store
        Waver.shared.store = store
    }

    var body: some View {
        Image(nsImage: MenuBarIcon.render(store: store, pose: waver.pose))
    }
}

/// Sways Clawd side to side, waving at each end, while any session is waiting on you
/// and briefly when the menu opens. Out of usage, Clawd lies still with X'd-out eyes.
/// Only the Clawd images observe it, so the panel itself never redraws.
@MainActor
final class Waver: ObservableObject {
    static let shared = Waver()

    @Published private(set) var pose = ClaudeMark.Pose()
    weak var store: Store?
    private static let path: [ClaudeMark.Pose] = [
        .init(shift: 0), .init(shift: 1), .init(shift: 2, armsUp: true), .init(shift: 2, armsUp: true),
        .init(shift: 1), .init(shift: 0), .init(shift: -1), .init(shift: -2, armsUp: true),
        .init(shift: -2, armsUp: true), .init(shift: -1),
    ]
    private var step = 0
    private var greetSteps = 0
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let waiting = !(store?.waiting.isEmpty ?? true)
        if greetSteps > 0 { greetSteps -= 1 }
        if store?.limitReached == true {
            step = 0
            if !pose.dead { pose = ClaudeMark.Pose(dead: true) }
            return
        }
        guard waiting || greetSteps > 0 else {
            step = 0
            if pose != ClaudeMark.Pose() { pose = ClaudeMark.Pose() }
            return
        }
        step = (step + 1) % Self.path.count
        pose = Self.path[step]
    }

    /// Two sways, ending back in the middle.
    func greet() {
        step = 0
        greetSteps = Self.path.count * 2
    }
}

struct HeaderMark: View {
    @ObservedObject private var waver = Waver.shared

    var body: some View {
        Image(nsImage: ClaudeMark.image(height: 14, color: ClaudeMark.orange, pose: waver.pose))
    }
}

enum MenuBarIcon {
    /// Waving orange Clawd + count when a session needs you; otherwise a template Clawd + 5h usage.
    @MainActor
    static func render(store: Store, pose: ClaudeMark.Pose) -> NSImage {
        let waiting = store.waiting.count
        if waiting > 0 {
            return draw(text: "\(waiting)", color: .systemOrange, pose: pose)
        }
        return draw(text: store.usage?.fiveHour.map { "\(Int($0.usedPercent.rounded()))%" }, color: nil, pose: pose)
    }

    private static func draw(text: String?, color: NSColor?, pose: ClaudeMark.Pose) -> NSImage {
        let tint = color ?? .black
        let mark = ClaudeMark.image(height: 13, color: tint, pose: pose)
        let attr = NSAttributedString(string: text ?? "", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: tint,
        ])
        let textSize = text == nil ? .zero : attr.size()
        let gap: CGFloat = text == nil ? 0 : 4
        let size = NSSize(width: ceil(mark.size.width + gap + textSize.width), height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            mark.draw(in: NSRect(x: 0, y: (rect.height - mark.size.height) / 2,
                                 width: mark.size.width, height: mark.size.height))
            attr.draw(at: NSPoint(x: mark.size.width + gap, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

/// Clawd, the Claude Code mascot, from the CLI welcome banner:
///  ▐▛███▜▌
/// ▝▜█████▛▘
///   ▘▘ ▝▝
/// Each block character is 2×2 pixels; terminal pixels are about twice as tall as wide.
enum ClaudeMark {
    static let orange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

    private static let pixels = [
        "...############...",
        "...##.######.##...",
        ".################.",
        "...############...",
        "....#.#....#.#....",
    ]

    /// Eyes filled in; `deadEyes` are cut out as X's on top.
    private static let deadPixels = [
        "...############...",
        "...############...",
        ".################.",
        "...############...",
        "....#.#....#.#....",
    ]
    private static let deadEyes = [5, 12]

    private static let wavingPixels = [
        ".#.############.#.",
        ".#.##.######.##.#.",
        ".################.",
        "...############...",
        "....#.#....#.#....",
    ]

    struct Pose: Equatable {
        /// Horizontal offset in mascot pixels, within -sway...sway.
        var shift = 0
        var armsUp = false
        var dead = false
    }

    /// How many mascot pixels Clawd can sway each way; the canvas is padded so its size never changes.
    static let sway = 2

    /// `height` is the drawn height in points; width follows the mascot's proportions.
    static func image(height: CGFloat, color: NSColor, pose: Pose = Pose()) -> NSImage {
        let pixels = pose.dead ? deadPixels : pose.armsUp ? wavingPixels : pixels
        let rows = CGFloat(pixels.count)
        let cols = CGFloat(pixels[0].count + 2 * sway)
        let ph = height / rows
        let pw = ph / 2
        let originX = CGFloat(sway + pose.shift) * pw
        return NSImage(size: NSSize(width: ceil(cols * pw), height: height), flipped: true) { _ in
            // One path, filled once, so neighbouring pixels don't show anti-aliased seams.
            let path = NSBezierPath()
            for (y, row) in pixels.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    path.appendRect(NSRect(x: originX + CGFloat(x) * pw, y: CGFloat(y) * ph, width: pw, height: ph))
                }
            }
            color.setFill()
            path.fill()

            if pose.dead {
                // Punch an X through each eye, centred on the eye pixel and spilling into its neighbours.
                let half = ph * 0.7
                let eyes = NSBezierPath()
                eyes.lineWidth = pw * 0.9
                eyes.lineCapStyle = .round
                for x in deadEyes {
                    let c = NSPoint(x: originX + (CGFloat(x) + 0.5) * pw, y: 1.5 * ph)
                    eyes.move(to: NSPoint(x: c.x - half, y: c.y - half))
                    eyes.line(to: NSPoint(x: c.x + half, y: c.y + half))
                    eyes.move(to: NSPoint(x: c.x - half, y: c.y + half))
                    eyes.line(to: NSPoint(x: c.x + half, y: c.y - half))
                }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                eyes.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            UsageCard(usage: store.usage)

            if store.waiting.isEmpty && store.busy.isEmpty {
                Text("No sessions working right now")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                sessionList
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Waver.shared.greet()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HeaderMark()
            Text("Claude Code")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !store.waiting.isEmpty { parts.append("\(store.waiting.count) waiting") }
        if !store.busy.isEmpty { parts.append("\(store.busy.count) working") }
        if parts.isEmpty { parts.append("All quiet") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var sessionList: some View {
        let list = VStack(alignment: .leading, spacing: 12) {
            section("Needs you", store.waiting)
            section("Working", store.busy)
        }
        let visibleRows = store.waiting.count + store.busy.count
        if visibleRows > 7 {
            ScrollView { list }.frame(height: 400)
        } else {
            list
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ sessions: [Session]) -> some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
                    .padding(.bottom, 2)
                ForEach(sessions) { s in
                    SessionRow(session: s) { store.focus(s) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: $store.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut("q")
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Usage

struct UsageCard: View {
    let usage: Usage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let usage, usage.fiveHour != nil || usage.sevenDay != nil {
                if let l = usage.fiveHour { LimitRow(title: "Session", detail: "5 hours", limit: l) }
                if let l = usage.sevenDay { LimitRow(title: "Weekly", detail: "7 days", limit: l) }
                if usage.updatedAt < Date().addingTimeInterval(-15 * 60) {
                    Text("Updated \(Format.ago(usage.updatedAt)) ago")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Usage limits show up after your next message in Claude Code.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct LimitRow: View {
    let title: String
    let detail: String
    let limit: Limit

    private var left: Int { max(0, 100 - Int(limit.usedPercent.rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Text("\(left)% left")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(left <= 10 ? Color.red : .primary)
            }
            Bar(fraction: limit.usedPercent / 100, color: Format.levelColor(limit.usedPercent))
            Text("Resets \(Format.reset(limit.resetsAt))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(fraction > 0 ? 5 : 0, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: Session
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: session.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let ctx = session.context {
                ContextRing(percent: ctx)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0))
        )
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .help(session.isBackground ? "Background session" : "Click to open its terminal")
    }

    private var subtitle: String {
        var parts: [String] = []
        if session.name != session.folder { parts.append(session.folder) }
        switch session.state {
        case .waiting(let reason): parts.append(Format.capitalized(reason))
        case .busy: parts.append("Working")
        case .idle: break
        }
        parts.append(Format.ago(session.since))
        return parts.joined(separator: " · ")
    }

    private var subtitleColor: Color {
        if case .waiting = session.state { return Color(nsColor: .systemOrange) }
        return .secondary
    }
}

struct StatusDot: View {
    let state: SessionState

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }

    private var color: Color {
        switch state {
        case .waiting: return Color(nsColor: .systemOrange)
        case .busy: return Color(nsColor: .systemBlue)
        case .idle: return Color.secondary.opacity(0.5)
        }
    }
}

struct ContextRing: View {
    let percent: Double

    var body: some View {
        HStack(spacing: 5) {
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: min(1, percent / 100))
                    .stroke(Format.levelColor(percent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
        }
        .help("Context window used")
    }
}

// MARK: - Formatting

enum Format {
    static func levelColor(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return Color(nsColor: .systemGreen)
        case ..<85: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }

    static func ago(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }

    static func reset(_ date: Date) -> String {
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        if s < 3600 { return "in \(s / 60)m" }
        if s < 86400 { return "in \(s / 3600)h \((s % 3600) / 60)m" }
        let f = DateFormatter()
        f.dateFormat = "EEE h:mm a"
        return f.string(from: date)
    }

    static func capitalized(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }
}
