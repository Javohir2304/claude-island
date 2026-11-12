import SwiftUI

// "Ember & Thread", after hey-claude's island motion spec (docs/island-motion.md):
// the ember is Claude's presence, the thread is the voice line. White thread = the user,
// terracotta thread = Claude. States are told apart by the thread's shape, not only colour.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

enum Palette {
    static let ash = Color(hex: 0x5C5652)
    static let banked = Color(hex: 0xB8664C)
    static let live = Color(hex: 0xD97757)
    static let hot = Color(hex: 0xEC9A78)
    static let whiteHot = Color(hex: 0xFFE3D6)
    static let cool = Color(hex: 0xB38A7A)
    static let user = Color(hex: 0xF2F2F2, alpha: 0.9)
    static let ok = Color(hex: 0x6CCB7A)
    static let bad = Color(hex: 0xE5646A)
    static let dim = Color(hex: 0x9A9A9A)
    static let amber = Color(hex: 0xF2B866)
    static let undoFill = Color(hex: 0x6B3A30)
    static let undoText = Color(hex: 0xF6C9B6)
}

/// Live audio levels, read by the animations every frame (kept out of @Published so a
/// 60 fps wave doesn't re-render the whole island).
final class Levels {
    static let shared = Levels()
    var mic: Double = 0                          // 0...1 from the recorder
    var voiceMeter: (() -> Double)?              // the Uzbek voice's live meter while it plays
    var voicePulse = Date.distantPast            // a system voice started a word
    var wokeAt = Date.distantPast                // "Hey Claude" (or the hotkey) fired

    func voice(at now: Date) -> Double {
        if let m = voiceMeter { return m() }
        let dt = now.timeIntervalSince(voicePulse)
        return dt >= 0 && dt < 0.6 ? 0.7 * exp(-dt / 0.16) : 0
    }
}

/// One-pole follower: y += (x − y)·(1 − e^(−dt/τ)), separate attack and release.
final class Follower {
    private(set) var value = 0.0
    private var last: Date?

    func step(_ target: Double, _ now: Date, attack: Double, release: Double) -> Double {
        guard let l = last else { last = now; value = target; return value }
        let dt = min(0.1, max(0, now.timeIntervalSince(l)))
        last = now
        value += (target - value) * (1 - exp(-dt / (target > value ? attack : release)))
        return value
    }
}

private func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
    let ra = NSColor(a).usingColorSpace(.sRGB) ?? .black, rb = NSColor(b).usingColorSpace(.sRGB) ?? .black
    let k = min(1, max(0, t))
    return Color(.sRGB, red: ra.redComponent + (rb.redComponent - ra.redComponent) * k,
                 green: ra.greenComponent + (rb.greenComponent - ra.greenComponent) * k,
                 blue: ra.blueComponent + (rb.blueComponent - ra.blueComponent) * k,
                 opacity: ra.alphaComponent + (rb.alphaComponent - ra.alphaComponent) * k)
}

private func breath(_ t: Double, _ hz: Double) -> Double {     // 0...1, inhale 40 %, exhale 60 %
    let p = (t * hz).truncatingRemainder(dividingBy: 1)
    if p < 0.4 { return sin(p / 0.4 * .pi / 2) }
    return 0.5 + 0.5 * cos((p - 0.4) / 0.6 * .pi)
}

enum VoiceMode: Equatable { case ready, off, listening, transcribing, thinking, speaking, done, error }

/// The state the island's voice is in, read from the model.
func voiceMode(_ m: IslandModel) -> VoiceMode {
    if m.micOn { return .listening }
    if m.transcribing { return .transcribing }
    if m.speaking { return .speaking }
    if m.phase == .thinking || (m.phase == .answering && m.answer.isEmpty) { return .thinking }
    if m.phase == .answering { return .speaking }
    return .ready
}

private final class ThreadState {
    let level = Follower(), voice = Follower(), glow = Follower()
    var history: [(Date, Double)] = []
    var phi = 0.0
    var pen = 3.2 * .pi + 7
    var last: Date?
    var ripples: [Date] = []
    var prevA: [(Date, Double)] = []
    let born = Date()

    func lagged(_ now: Date, _ d: Double) -> Double {
        let t = now.addingTimeInterval(-d)
        return history.last(where: { $0.0 <= t })?.1 ?? history.first?.1 ?? 0
    }
}

/// The ember and its thread, drawn every frame.
struct EmberThread: View {
    var mode: VoiceMode
    var emberX: CGFloat = 14
    var field: CGFloat = 150            // thread length for the voice states
    var showGlow = true
    var bleed: CGFloat = 26             // the glow may spill this far past the frame
    @State private var st = ThreadState()

    private var fps: Double {
        switch mode {
        case .ready, .off, .error: return 12
        case .done: return 30
        default: return 60
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps)) { ctx in
            Canvas { g, size in
                g.translateBy(x: bleed, y: bleed)
                draw(&g, CGSize(width: size.width - 2 * bleed, height: size.height - 2 * bleed), ctx.date)
            }
        }
        .padding(-bleed)
        .allowsHitTesting(false)
    }

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        let dt = min(0.1, max(0, now.timeIntervalSince(st.last ?? now)))
        st.last = now
        let cy = size.height / 2, ex = emberX

        let rawMic = mode == .listening ? pow(min(1, max(0, (Levels.shared.mic - 0.04) / 0.75)), 0.7) : 0
        let L = st.level.step(rawMic, now, attack: 0.03, release: 0.18)
        st.history.append((now, L))
        st.history.removeAll { now.timeIntervalSince($0.0) > 0.5 }
        let A = st.voice.step(mode == .speaking ? Levels.shared.voice(at: now) : 0, now, attack: 0.025, release: 0.14)

        // ember: colour, radius, glow
        var color = Palette.live, r = 4.0, glowA = 0.10, glowR = 22.0
        switch mode {
        case .ready:
            let b = breath(t, 0.25)
            color = mix(Palette.banked, Palette.live, b); r = 3.9 + 0.4 * b; glowA = 0.06 + 0.06 * b; glowR = 18 + 8 * b
        case .off:
            color = Palette.ash; r = 3; glowA = 0
        case .listening:
            color = Palette.live; r = 5 + 2.5 * L; glowA = 0.12 + 0.24 * L; glowR = 24 + 30 * L
        case .transcribing, .thinking:
            r = 4 + 0.3 * sin(2 * .pi * 0.4 * t); glowA = 0.12; glowR = 24
        case .speaking:
            r = 4 + 3 * A; glowA = 0.10 + 0.2 * A; glowR = 24 + 26 * A
            if A < 0.03 { r += 0.25 * sin(2 * .pi * 0.5 * t) }
        case .done:
            let k = min(1, now.timeIntervalSince(st.born) / 1.1)
            color = mix(Palette.ok, Palette.live, max(0, (k - 0.6) / 0.4)); r = 4 + 1.4 * max(0, 1 - k * 2); glowA = 0.16 * (1 - k) + 0.06
        case .error:
            color = Palette.bad; r = 4 + 0.3 * sin(2 * .pi * 0.25 * t); glowA = 0.07
        }

        // the catch: "Hey Claude" just fired (420 ms)
        let w = now.timeIntervalSince(Levels.shared.wokeAt)
        var ring: (Double, Double)?
        if w >= 0 && w < 0.42 {
            if w < 0.08 { color = Palette.whiteHot; r = 3.2 }
            else if w < 0.16 { color = mix(Palette.whiteHot, Palette.hot, (w - 0.08) / 0.08); r = 6.5 }
            else { color = mix(Palette.hot, color, (w - 0.16) / 0.26); r = 6.5 + (r - 6.5) * (w - 0.16) / 0.26 }
            glowA = max(glowA, 0.42 * (1 - w / 0.42)); glowR = max(glowR, 60)
            if w > 0.12 { let k = (w - 0.12) / 0.3; ring = (6 + 34 * (1 - pow(1 - k, 3)), 0.5 * (1 - k)) }
        }

        let center = CGPoint(x: ex, y: cy)
        if showGlow && glowA > 0 {
            let rect = CGRect(x: ex - glowR, y: cy - glowR, width: glowR * 2, height: glowR * 2)
            g.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [color.opacity(glowA), color.opacity(0)]),
                                                                 center: center, startRadius: 0, endRadius: glowR))
        }
        if let (rr, a) = ring {
            g.stroke(Path(ellipseIn: CGRect(x: ex - rr, y: cy - rr, width: rr * 2, height: rr * 2)),
                     with: .color(Palette.hot.opacity(a)), lineWidth: 1.5)
        }
        // heat ripples while speaking
        st.prevA.append((now, A))
        st.prevA.removeAll { now.timeIntervalSince($0.0) > 0.06 }
        if mode == .speaking, let first = st.prevA.first, A - first.1 > 0.18, A > 0.25,
           st.ripples.filter({ now.timeIntervalSince($0) < 0.52 }).count < 2,
           now.timeIntervalSince(st.ripples.last ?? .distantPast) > 0.16 {
            st.ripples.append(now)
        }
        st.ripples.removeAll { now.timeIntervalSince($0) > 0.52 }
        for rp in st.ripples {
            let k = now.timeIntervalSince(rp) / 0.52, e = 1 - pow(1 - k, 3)
            let rr = 5 + 19 * e
            g.stroke(Path(ellipseIn: CGRect(x: ex - rr, y: cy - rr, width: rr * 2, height: rr * 2)),
                     with: .color(Palette.live.opacity(0.3 * (1 - k))), lineWidth: 1.5 - e)
        }
        g.fill(Path(ellipseIn: CGRect(x: ex - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(color))
        if mode != .off {
            let core = r * 0.5
            let coreColor = (mode == .listening && L > 0.35) || A > 0.4 ? Palette.whiteHot : Palette.hot
            g.fill(Path(ellipseIn: CGRect(x: ex - core, y: cy - core, width: core * 2, height: core * 2)),
                   with: .color(coreColor.opacity(0.85)))
        } else {
            var slash = Path()
            slash.move(to: CGPoint(x: ex - 5, y: cy + 5)); slash.addLine(to: CGPoint(x: ex + 5, y: cy - 5))
            g.stroke(slash, with: .color(.black), lineWidth: 3)
            g.stroke(slash, with: .color(Palette.dim), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // the thread
        let x0 = ex + 14
        switch mode {
        case .listening:
            let x1 = min(size.width - 4, x0 + field)
            var p = Path()
            var x = x0
            while x <= x1 {
                let u = Double((x - x0) / max(1, x1 - x0))
                let env = pow(sin(.pi * u), 0.8)
                let amp = min(11, 0.6 + 10.5 * st.lagged(now, 0.36 * (1 - u))) * Double(size.height) / 40
                let y = cy + CGFloat(amp * env * sin(2 * .pi * (Double(x) / 22 + 1.1 * t)))
                if x == x0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                x += 2
            }
            g.stroke(p, with: .color(Palette.user), style: StrokeStyle(lineWidth: 1.75 + 0.5 * L, lineCap: .round, lineJoin: .round))
        case .thinking, .transcribing:
            // the pen writes: a prolate cycloid, ink drying behind the pen
            let rr = 1.9 * Double(size.height) / 40 * 1.2, d = 4.5 * Double(size.height) / 40 * 1.2
            let fieldW = Double(min(field, 44))
            let span = fieldW / rr                        // θ across the field
            let speed = mode == .transcribing ? 0.75 : 1.0
            st.pen += dt * speed * 2 * .pi / 0.38
            let pen = st.pen.truncatingRemainder(dividingBy: span + 3.2 * .pi)
            let ink = mode == .transcribing ? Palette.user : Palette.live
            let steps = 70
            var prev: CGPoint?
            for i in 0...steps {
                let q = Double(i) / Double(steps)
                let th = pen - 3.2 * .pi * (1 - q)
                guard th >= 0, th <= span else { prev = nil; continue }
                let pt = CGPoint(x: x0 + CGFloat(rr * th - d * sin(th)), y: cy - CGFloat(d * cos(th)))
                if let pr = prev {
                    var seg = Path(); seg.move(to: pr); seg.addLine(to: pt)
                    g.stroke(seg, with: .color(ink.opacity(pow(q, 0.8))), style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                }
                prev = pt
            }
        case .speaking:
            st.phi += dt * 0.9 * (1 + 1.5 * A)
            let x1 = min(size.width - 4, x0 + min(field, 60))
            var p = Path()
            var x = x0
            let amp = (0.8 + 8 * pow(A, 0.7)) * Double(size.height) / 40
            while x <= x1 {
                let u = Double((x - x0) / max(1, x1 - x0))
                let env = pow(sin(.pi * u), 1.2)
                let y = cy + CGFloat(amp * env * (sin(2 * .pi * (2 * u - st.phi)) + 0.35 * sin(2 * .pi * (4.6 * u - 1.6 * st.phi))))
                if x == x0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                x += 1.5
            }
            g.stroke(p, with: .color(Palette.live), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        case .done:
            let k = min(1, max(0, (now.timeIntervalSince(st.born) - 0.24) / 0.24))
            var c = Path()
            c.move(to: CGPoint(x: ex + 10, y: cy)); c.addLine(to: CGPoint(x: ex + 14, y: cy + 4)); c.addLine(to: CGPoint(x: ex + 23, y: cy - 5))
            g.stroke(c.trimmedPath(from: 0, to: 1 - pow(1 - k, 3)), with: .color(Palette.ok),
                     style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        default:
            break
        }
    }
}

/// A small ember with satellites: one per running task, orbiting once per 10 s.
struct OrbitEmber: View {
    var count: Int
    var waiting = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let b = breath(t, 0.5)
                let color = waiting ? Palette.amber : mix(Palette.banked, Palette.live, b)
                let gr = 10.0
                g.fill(Path(ellipseIn: CGRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2)),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.25), color.opacity(0)]), center: c, startRadius: 0, endRadius: gr))
                let r = 3.4 + 0.3 * b
                g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
                let n = max(1, min(3, count))
                for i in 0..<n {
                    let a = 2 * .pi * (t / 4 + Double(i) / Double(n))
                    let p = CGPoint(x: c.x + 8 * cos(a), y: c.y + 8 * sin(a))
                    g.fill(Path(ellipseIn: CGRect(x: p.x - 1.4, y: p.y - 1.4, width: 2.8, height: 2.8)), with: .color(Palette.hot))
                }
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// A check mark that draws itself in.
struct DrawnCheck: View {
    var color: Color = Palette.ok
    @State private var k: CGFloat = 0

    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 2, y: 7)); p.addLine(to: CGPoint(x: 6, y: 11)); p.addLine(to: CGPoint(x: 14, y: 3))
        }
        .trim(from: 0, to: k)
        .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        .frame(width: 16, height: 14)
        .onAppear { withAnimation(.timingCurve(0.2, 0, 0, 1, duration: 0.36).delay(0.12)) { k = 1 } }
    }
}

/// The ember-coloured wash and rim that make the whole pill feel alive while it listens or talks.
struct PillAura: View {
    var mode: VoiceMode
    var center: CGPoint
    @State private var f = Follower()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: mode == .ready)) { ctx in
            Canvas { g, size in
                let now = ctx.date
                let w = now.timeIntervalSince(Levels.shared.wokeAt)
                let woke = w >= 0 && w < 0.6 ? 1 - w / 0.6 : 0
                var target: Double
                switch mode {
                case .listening: target = 0.14 + 0.22 * min(1, Levels.shared.mic * 1.3)
                case .speaking: target = 0.10 + 0.18 * Levels.shared.voice(at: now)
                case .thinking, .transcribing: target = 0.09
                default: target = 0.0
                }
                let a = f.step(max(target, 0.35 * woke), now, attack: 0.05, release: 0.25)
                guard a > 0.005 else { return }
                let R = max(size.width * 0.75, 260)
                g.fill(Path(CGRect(origin: .zero, size: size)),
                       with: .radialGradient(Gradient(colors: [Palette.live.opacity(a), Palette.live.opacity(a * 0.35), Palette.live.opacity(0)]),
                                             center: center, startRadius: 0, endRadius: R))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Hairline between rows.
struct Hairline: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.09)).frame(height: 1) }
}

/// "icon  Title · detail" above a card.
struct CardHeader: View {
    var icon: String
    var title: String
    var detail: String = ""
    var tint: Color = .white.opacity(0.75)

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint).frame(width: 16)
            Text("\(Text(title).foregroundStyle(.white.opacity(0.85)))\(Text(detail.isEmpty ? "" : " · \(detail)").foregroundStyle(.white.opacity(0.5)))")
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// Round head-row control (mic, stop), after hey-claude's 24 px circles.
struct RoundControl: View {
    var symbol: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white.opacity(0.92))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hover ? 0.2 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressDip())
        .onHover { hover = $0 }
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}

struct PressDip: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.22), value: configuration.isPressed)
    }
}

/// The muted terracotta Undo pill.
struct UndoPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.undoText)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(Palette.undoFill.opacity(configuration.isPressed ? 0.7 : 1)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .contentShape(Capsule())
    }
}
