import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shape

/// The island's outline: flush with the top of the screen, with small outward flares
/// where it meets the edge (like the hardware notch) and round bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let tr = min(topRadius, r.height / 2)
        let br = max(0, min(bottomRadius, r.height - tr, (r.width - 2 * tr) / 2))
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + tr, y: r.minY + tr), control: CGPoint(x: r.minX + tr, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + tr, y: r.maxY - br))
        p.addQuadCurve(to: CGPoint(x: r.minX + tr + br, y: r.maxY), control: CGPoint(x: r.minX + tr, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - tr - br, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - tr, y: r.maxY - br), control: CGPoint(x: r.maxX - tr, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY + tr))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - tr, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct PillSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Hugs its content up to maxHeight, then scrolls.
struct FittedScroll<Content: View>: View {
    var maxHeight: CGFloat
    var bottom = false              // start at the end (the newest card)
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content.background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        .defaultScrollAnchor(bottom ? .bottom : .top)
        .frame(height: min(max(height, 18), maxHeight))
        .onPreferenceChange(HeightKey.self) { height = $0 }
    }
}

// MARK: - Small pieces

/// Claude's presence: a warm dot that breathes when ready and gets an orbiting arc while working.
struct Ember: View {
    enum Mode { case still, breathing, working }
    var mode: Mode = .still
    var size: CGFloat = 10
    var color: Color = emberColor

    var body: some View {
        if mode == .still {
            dot(scale: 1, angle: 0, arc: false)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                dot(scale: mode == .breathing ? 0.88 + 0.12 * sin(t * 2.2) : 0.8,
                    angle: t * 300, arc: mode == .working)
            }
        }
    }

    private func dot(scale: Double, angle: Double, arc: Bool) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.35)).frame(width: size * 1.5, height: size * 1.5).blur(radius: size * 0.35)
            Circle().fill(color).frame(width: size, height: size).scaleEffect(scale)
            if arc {
                Circle().trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: size * 1.7, height: size * 1.7)
                    .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: size * 1.8, height: size * 1.8)
    }
}

struct AudioBars: View {
    var playing: Bool
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let h = playing ? 4 + 9 * abs(sin(t * (3.1 + Double(i) * 0.9) + Double(i) * 1.7)) : 3
                    Capsule().fill(color).frame(width: 2.5, height: h)
                }
            }
            .frame(width: 18, height: 14)
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var primary = false
    var tint: Color = emberColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(primary ? Color.black : Color.white.opacity(0.92))
            .padding(.horizontal, 13)
            .padding(.vertical, 6.5)
            .background(Capsule().fill(primary ? tint : Color.white.opacity(configuration.isPressed ? 0.24 : 0.13)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

struct IconButton: View {
    var symbol: String
    var size: CGFloat = 13
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.75))
                .frame(width: size + 15, height: size + 15)
                .background(Circle().fill(Color.white.opacity(hover ? 0.16 : 0.0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - The island

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @State private var bubbleW: CGFloat = 0
    private let flare: CGFloat = 7

    private func isPanel(_ l: Layout) -> Bool { l == .dashboard || l == .assistant || l == .approval }

    private func width(_ l: Layout) -> CGFloat {
        switch l {
        case .idle: return model.hasNotch ? model.notch.width - 2 * flare : model.notch.width   // hidden behind the notch
        case .compact: let s = compactSides(model.activities); return s.0 + model.notch.width + s.1
        case .flash: return model.notch.width + 2 * 136
        case .dashboard, .assistant, .approval: return max(model.notch.width + 300, 500)
        }
    }

    /// Side widths for the compact island: equal sides around the notch for one activity
    /// (balanced, snug), a leading side only when the next activity is detached.
    private func compactSides(_ acts: [LiveActivity]) -> (CGFloat, CGFloat) {
        guard let a = acts.first else { return (40, 40) }
        let lead: CGFloat = 40
        if acts.count > 1 {
            // attached minimal: the timer keeps its remaining time, as on iPhone
            if case .timer = a { return (86, 12) }
            return (lead, 12)
        }
        let trail: CGFloat
        switch a {
        case .timer: trail = 58
        case .working(let s): trail = s.count > 1 ? 40 : 54
        case .waiting(let s): trail = min(110, CGFloat(s.project.count) * 7.5 + 20)
        default: trail = 40
        }
        let side = max(lead, trail)
        return (side, side)
    }

    var body: some View {
        let layout = model.layout
        let acts = model.activities
        let sides = compactSides(acts)
        let offset: CGFloat = layout == .compact ? (sides.1 - sides.0) / 2 : 0
        VStack(spacing: 0) {
            if layout == .compact {
                CompactRow(model: model, activities: acts, sides: sides)
            } else {
                TopRow(model: model, layout: layout)
            }
            if isPanel(layout) {
                panel(layout)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(width: width(layout))
        .padding(.horizontal, flare)
        .background(ZStack {
            Color.black
            if layout == .assistant {
                PillAura(mode: voiceMode(model), center: CGPoint(x: flare + 15 + 13, y: model.notch.height + 26))
                    .mask(notchSafeMask)
            }
        })
        .clipShape(NotchShape(topRadius: flare, bottomRadius: isPanel(layout) ? 26 : 11))
        .overlay(rim(layout))
        .overlay(keyLine(layout, acts))
        .overlay(alignment: .topTrailing) {
            if layout == .compact, acts.count > 1 {
                MinimalBubble(activity: acts[1], height: model.notch.height - 4)
                    .id(acts[1].id)
                    .fixedSize()
                    .background(GeometryReader { g in
                        Color.clear.onAppear { bubbleW = g.size.width; model.bubbleWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in bubbleW = w; model.bubbleWidth = w }
                    })
                    .onDisappear { model.bubbleWidth = 0 }
                    .padding(.top, 2)
                    .offset(x: bubbleW + 6)
                    .transition(.scale(scale: 0.2, anchor: .leading).combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(isPanel(layout) ? 0.5 : 0), radius: 16, y: 8)
        .background(GeometryReader { g in Color.clear.preference(key: PillSizeKey.self, value: g.size) })
        .onPreferenceChange(PillSizeKey.self) { model.pillSize = $0 }
        .offset(x: offset)
        .onChange(of: offset, initial: true) { _, o in model.pillOffset = o }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { urls.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { if !urls.isEmpty { model.onDropFiles(urls) } }
            return true
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.76), value: layout)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: acts.map(\.id))
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: model.sessions.count)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: model.approvals.first?.id)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: model.phase)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: model.cards)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    /// The strip beside the camera stays pure black, like the hardware notch, so the
    /// cut-out never shows against a tinted panel (HIG: diminish the camera's presence).
    private var notchSafeMask: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notch.height + 2)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 22)
            Color.black
        }
    }

    /// HIG: on a dark background a key line in the activity's colour outlines the island.
    @ViewBuilder private func keyLine(_ layout: Layout, _ acts: [LiveActivity]) -> some View {
        if layout == .compact || layout == .flash {
            let tint: Color = layout == .flash ? (model.flash?.tint ?? .white) : (acts.first.map(activityTint) ?? .white)
            NotchShape(topRadius: flare, bottomRadius: 11)
                .stroke(tint.opacity(0.32), lineWidth: 1)
                .mask(VStack(spacing: 0) {
                    Color.clear.frame(height: model.notch.height * 0.35)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    Color.black
                })
                .allowsHitTesting(false)
        }
    }

    /// A thin rim that warms with the voice (hidden along the screen edge).
    @ViewBuilder private func rim(_ layout: Layout) -> some View {
        if isPanel(layout) {
            let mode = voiceMode(model)
            let color: Color = layout == .approval ? Palette.amber.opacity(0.35)
                : layout != .assistant ? Color.white.opacity(0.09)
                : mode == .listening ? Palette.live.opacity(0.5)
                : mode == .speaking ? Palette.live.opacity(0.35)
                : mode == .thinking || mode == .transcribing ? Palette.live.opacity(0.22) : Color.white.opacity(0.1)
            NotchShape(topRadius: flare, bottomRadius: 26)
                .stroke(color, lineWidth: 1.2)
                .mask(VStack(spacing: 0) {
                    Color.clear.frame(height: model.notch.height * 0.55)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 16)
                    Color.black
                })
                .animation(.easeOut(duration: 0.25), value: mode)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func panel(_ layout: Layout) -> some View {
        switch layout {
        case .dashboard: DashboardPanel(model: model)
        case .assistant: AssistantPanel(model: model)
        case .approval:
            if let card = model.approvals.first { ApprovalPanel(model: model, card: card).id(card.id) }
        default: EmptyView()
        }
    }
}

/// The compact island: one activity's leading and trailing views snug around the notch,
/// or (with more) the first one's minimal view attached on the leading side.
struct CompactRow: View {
    @ObservedObject var model: IslandModel
    var activities: [LiveActivity]
    var sides: (CGFloat, CGFloat)

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if let a = activities.first {
                    Group {
                        if activities.count > 1, case .timer(let t) = a {
                            HStack(spacing: 5) {
                                TimerRing(timer: t, size: 15)
                                Countdown(end: t.end).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Palette.hot)
                            }
                        } else {
                            CompactLeading(activity: a)
                        }
                    }
                    .id(a.id).transition(.blurReplace.combined(with: .scale(0.7)))
                }
            }
            .frame(width: sides.0)
            Color.clear.frame(width: model.notch.width)
            ZStack {
                if activities.count == 1, let a = activities.first {
                    CompactTrailing(activity: a).id(a.id).transition(.blurReplace.combined(with: .scale(0.7)))
                }
            }
            .frame(width: sides.1)
        }
        .frame(height: model.notch.height)
        .contentShape(Rectangle())
        .onTapGesture { model.onOpenActivity(activities.first) }
    }
}

/// The strip at the height of the notch: whatever fits beside it.
struct TopRow: View {
    @ObservedObject var model: IslandModel
    var layout: Layout

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, alignment: .leading)
            center.frame(width: model.notch.width)
            right.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, layout == .idle ? 0 : 9)
        .frame(height: model.notch.height)
    }

    @ViewBuilder private var center: some View {
        if !model.hasNotch && layout == .idle {
            Ember(mode: .still, size: 7).opacity(0.8)
        } else {
            Color.clear
        }
    }

    private func label(_ s: String, dim: Bool = false) -> some View {
        Text(s).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(dim ? 0.6 : 0.95)).lineLimit(1)
    }

    @ViewBuilder private var left: some View {
        switch layout {
        case .idle:
            EmptyView()
        case .compact:
            if let m = model.media, m.playing {
                Artwork(image: m.artwork, size: 20)
            } else if !model.timers.isEmpty {
                Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(emberColor)
            } else if model.workingSessions.isEmpty && !model.answeredQueue.isEmpty {
                Image(systemName: "tray.full.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(emberColor)
            } else {
                OrbitEmber(count: model.workingSessions.count,
                           waiting: model.workingSessions.contains { $0.status == .waiting })
            }
        case .flash:
            if let f = model.flash {
                HStack(spacing: 6) {
                    if f.icon.hasPrefix("checkmark") {
                        DrawnCheck(color: f.tint == .white ? Palette.ok : f.tint).id(f.id)
                    } else {
                        Image(systemName: f.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(f.tint)
                            .symbolEffect(.bounce, value: f.id)
                    }
                    label(f.left)
                }
                .id(f.id)
                .transition(.blurReplace)
            }
        case .dashboard:
            HStack(spacing: 5) {
                EmberThread(mode: model.claude.isReady ? .ready : .off, emberX: 8).frame(width: 16, height: 20)
                label("Orol")
                if model.wakeListening {
                    Text("hey claude").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
                }
                if !model.claude.isReady {
                    Image(systemName: model.claude.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                }
            }
        case .assistant:
            HStack(spacing: 6) {
                Text(phaseLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                    .contentTransition(.opacity)
                if !model.claude.isReady {
                    Image(systemName: model.claude.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.leading, 6)
        case .approval:
            HStack(spacing: 6) {
                OrbitEmber(count: 1, waiting: true).scaleEffect(0.8)
                label("ruxsat kerak", dim: true)
            }
        }
    }

    private var emberTint: Color { model.claude.isReady ? emberColor : Color(white: 0.55) }

    private var phaseLabel: String {
        if model.micOn { return "tinglayapman" }
        if model.transcribing { return "tanib olyapman" }
        if model.speaking { return "gapiryapman" }
        switch model.phase {
        case .thinking: return "oʻylayapman"
        case .answering, .done: return "javob"
        default: return model.wakeListening ? "orol · hey claude" : "orol"
        }
    }

    @ViewBuilder private var right: some View {
        switch layout {
        case .idle:
            EmptyView()
        case .compact:
            let busy = model.workingSessions
            if busy.contains(where: { $0.status == .waiting }) {
                Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 12)).foregroundStyle(.yellow)
            } else if !busy.isEmpty {
                label(busy.count > 1 ? "\(busy.count) ta" : "ishlayapti", dim: true)
            } else if let t = model.timers.min(by: { $0.end < $1.end }) {
                Countdown(end: t.end).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(emberColor)
            } else if !(model.media?.playing ?? false) && !model.answeredQueue.isEmpty {
                label("\(model.answeredQueue.count)")
            } else {
                AudioBars(playing: model.media?.playing ?? false)
            }
        case .flash:
            if let f = model.flash { label(f.right, dim: true).id(f.id).transition(.blurReplace) }
        case .dashboard:
            if model.battery.present {
                HStack(spacing: 4) {
                    label("\(model.battery.percent)%", dim: true)
                    Image(systemName: model.battery.charging || model.battery.plugged ? "bolt.fill" : "battery.75")
                        .font(.system(size: 10)).foregroundStyle(model.battery.plugged ? .green : .white.opacity(0.6))
                }
            }
        case .assistant:
            IconButton(symbol: "xmark", size: 10) { model.onDismiss() }
        case .approval:
            if model.approvals.count > 1 { label("yana \(model.approvals.count - 1) ta", dim: true) }
        }
    }
}

struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var fallback = ""

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Palette.hot, Palette.banked], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if initials.isEmpty || size < 30 {
                        Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    } else {
                        Text(initials).font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(.white.opacity(0.92))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var initials: String {
        String(fallback.split(separator: " ").prefix(2).compactMap { $0.first }).uppercased()
    }
}

struct Countdown: View {
    var end: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            Text(formatClock(end.timeIntervalSince(ctx.date)))
        }
    }
}

// MARK: - Dashboard (hover)

struct DashboardPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 9) {
            askRow
            ClaudeStatusLine(model: model)
            if !model.queue.isEmpty { QueueList(model: model) }
            if let m = model.media { MediaCard(model: model, media: m) }
            if !model.sessions.isEmpty {
                VStack(spacing: 2) {
                    ForEach(model.sessions.suffix(5).reversed()) { s in SessionRow(session: s) { model.onJump(s) } }
                }
            }
            ForEach(model.timers) { t in TimerRow(timer: t) { model.onCancelTimer(t) } }
            if !model.hooksInstalled { hooksHint }
        }
        .padding(.horizontal, 13)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var askRow: some View {
        HStack(spacing: 8) {
            Button { model.onOpenInput(false) } label: {
                HStack(spacing: 8) {
                    EmberThread(mode: model.claude.isReady ? .ready : .off, emberX: 9).frame(width: 18, height: 30)
                    Text(model.claude.isReady ? "Claude’dan soʻrang…" : "Buyruq yozing — taymer, hisob, ilova…")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(model.hotkeyLabel).font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.09)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.onOpenInput(true) } label: {
                Image(systemName: "mic.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.09)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var hooksHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            Text("Claude Code sessiyalarini kuzatish yoqilmagan").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 4)
            Button("Yoqish") { model.onInstallHooks() }.buttonStyle(PillButtonStyle())
        }
        .padding(.leading, 4)
    }
}

struct MediaCard: View {
    @ObservedObject var model: IslandModel
    var media: MediaInfo
    var boxed = true

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Artwork(image: media.artwork, size: boxed ? 42 : 54, fallback: media.artist.isEmpty ? media.title : media.artist)
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(media.artist.isEmpty ? media.appName : media.artist).font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if true {
                HStack(spacing: 2) {
                    IconButton(symbol: "backward.fill", size: 13) { model.onMedia("previous") }
                    Button { model.onMedia("playpause") } label: {
                        Image(systemName: media.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black.opacity(0.85))
                            .frame(width: 32, height: 32).background(Circle().fill(Palette.hot))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressDip())
                    IconButton(symbol: "forward.fill", size: 13) { model.onMedia("next") }
                }
                }
            }
            if !boxed { VolumeRow() }
            if let d = media.duration, d > 0, media.position != nil {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let pos = media.currentPosition(at: ctx.date) ?? 0
                    HStack(spacing: 7) {
                        Text(formatClock(pos)).frame(width: 34, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.14))
                                Capsule().fill(Palette.hot).frame(width: g.size.width * CGFloat(min(1, pos / d)))
                            }
                        }
                        .frame(height: 3.5)
                        Text(formatClock(d)).frame(width: 34, alignment: .trailing)
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(boxed ? 10 : 0)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(boxed ? 0.06 : 0)))
    }
}

/// The Mac's output volume, as a slider (no permission needed).
struct VolumeRow: View {
    @State private var level: Double = SystemVolume.get()
    @State private var lastSent = Date.distantPast

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: level < 0.01 ? "speaker.slash.fill" : level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).frame(width: 18)
                .contentTransition(.symbolEffect(.replace))
            Slider(value: $level, in: 0...1) { editing in if !editing { SystemVolume.set(level) } }
                .controlSize(.mini)
                .tint(Palette.hot)
                .onChange(of: level) { _, v in
                    if Date().timeIntervalSince(lastSent) > 0.08 { lastSent = Date(); SystemVolume.set(v) }
                }
            Text("\(Int((level * 100).rounded()))%").font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55)).frame(width: 32, alignment: .trailing)
                .contentTransition(.numericText())
        }
        .onAppear { level = SystemVolume.get() }
    }
}

struct SessionRow: View {
    var session: SessionInfo
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                indicator.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text(session.project).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        if session.isTask { tag("vazifa") }
                        if session.subagents > 0 { tag("\(session.subagents) agent") }
                        Spacer(minLength: 4)
                        if session.plus + session.minus > 0 {
                            Text("+\(session.plus)").foregroundStyle(.green.opacity(0.9))
                            Text("−\(session.minus)").foregroundStyle(.red.opacity(0.9))
                        }
                        if session.status == .working { Elapsed(since: session.turnStarted) }
                    }
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    Text(line).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(emberColor)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(emberColor.opacity(0.16)))
    }

    private var line: String {
        switch session.status {
        case .working: return session.ticker.isEmpty ? (session.prompt.isEmpty ? "Ishlayapti…" : session.prompt) : session.ticker
        case .waiting: return "Javobingizni kutyapti"
        case .done: return session.summary.isEmpty ? (session.prompt.isEmpty ? "Tugadi" : session.prompt) : session.summary
        case .failed: return session.summary.isEmpty ? "Xato bilan toʻxtadi" : session.summary
        case .idle: return session.prompt.isEmpty ? "Kutmoqda" : session.prompt
        }
    }

    @ViewBuilder private var indicator: some View {
        switch session.status {
        case .working: Ember(mode: .working, size: 8)
        case .waiting: Image(systemName: "exclamationmark.bubble.fill").font(.system(size: 12)).foregroundStyle(.yellow)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").font(.system(size: 13)).foregroundStyle(.red)
        case .idle: Circle().fill(Color.white.opacity(0.3)).frame(width: 6, height: 6)
        }
    }
}

struct Elapsed: View {
    var since: Date
    var tint: Color = .white.opacity(0.45)
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(formatClock(ctx.date.timeIntervalSince(since))).foregroundStyle(tint)
        }
    }
}

struct TimerRow: View {
    var timer: TimerItem
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "timer").font(.system(size: 13, weight: .semibold)).foregroundStyle(emberColor).frame(width: 18)
            Text(timer.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
            Spacer()
            Countdown(end: timer.end).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            IconButton(symbol: "xmark", size: 9, action: cancel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

// MARK: - Assistant (talk or type)

struct AssistantPanel: View {
    @ObservedObject var model: IslandModel
    @FocusState private var focused: Bool

    /// The ember-and-thread row shows whenever the voice is doing something.
    private var showsHead: Bool { model.phase != .input || model.micOn || model.transcribing }
    private var showsInput: Bool {
        !model.micOn && !model.transcribing && (model.phase == .input || (model.phase == .done && !model.speaking))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHead {
                VoiceHead(model: model)
                    // the glow may spill sideways and down, never up next to the camera
                    .mask(Rectangle().padding(EdgeInsets(top: -2, leading: -60, bottom: -60, trailing: -60)))
                if !model.cards.isEmpty || !model.answer.isEmpty || showsInput { Hairline().padding(.top, 6) }
            }
            VStack(alignment: .leading, spacing: 11) {
                if !model.cards.isEmpty {
                    FittedScroll(maxHeight: 400, bottom: true) {
                        VStack(alignment: .leading, spacing: 11) {
                            // (glows and gauges may reach a few points past a card's edge)
                            ForEach(Array(model.cards.enumerated()), id: \.element.kindKey) { i, c in
                                CardView(model: model, card: c)
                                if i < model.cards.count - 1 { Hairline() }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .padding(.horizontal, -6)
                    if !model.answer.isEmpty { Hairline() }
                }
                if !model.answer.isEmpty { answer }
                if showsInput { inputRow }
                if !model.micNote.isEmpty {
                    Text(model.micNote).font(.system(size: 11)).foregroundStyle(Palette.amber).lineLimit(2)
                }
            }
            .padding(.top, showsHead && (!model.cards.isEmpty || !model.answer.isEmpty || showsInput) ? 11 : 0)
        }
        .padding(.horizontal, 15)
        .padding(.top, 2)
        .padding(.bottom, 13)
    }

    private var answer: some View {
        FittedScroll(maxHeight: 230) {
            Text(model.answer).font(.system(size: 14.5, weight: .medium)).foregroundStyle(.white).lineSpacing(2.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            EmberThread(mode: model.claude.isReady ? .ready : .off, emberX: 10, showGlow: true).frame(width: 20, height: 34)
            TextField(!model.claude.isReady ? "Taymer, hisob, ilova ochish… (“yordam”)"
                      : (model.phase == .done ? "Davom eting…" : "Yozing yoki gapiring…"),
                      text: $model.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { model.onSubmit(model.inputText, false) }
            RoundControl(symbol: "mic.fill") { model.onToggleMic() }
            if !model.inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { model.onSubmit(model.inputText, false) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 26, height: 26).background(Circle().fill(Palette.hot))
                }
                .buttonStyle(PressDip())
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.live.opacity(focused ? 0.35 : 0), lineWidth: 1))
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: model.focusToken) { _, _ in focused = true }
    }
}

/// hey-claude's head row: ember + thread, then what's being heard, thought or said, then
/// the round controls. The thread's shape tells the state: a wave flowing in while it
/// listens, a pen writing loops while it thinks, a wave flowing out while it speaks.
struct VoiceHead: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let mode = voiceMode(model)
        HStack(spacing: 8) {
            EmberThread(mode: mode, emberX: 13, field: threadField(mode))
                .frame(width: threadWidth(mode), height: 40)
            headline(mode)
                .frame(maxWidth: .infinity, alignment: .leading)
            controls(mode)
        }
        .frame(height: 42)
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: mode)
    }

    private func threadWidth(_ m: VoiceMode) -> CGFloat {
        switch m {
        case .listening: return model.inputText.isEmpty ? 190 : 120
        case .thinking, .transcribing: return 74
        case .speaking: return 92
        default: return 28
        }
    }

    private func threadField(_ m: VoiceMode) -> CGFloat {
        switch m {
        case .listening: return threadWidth(m) - 32
        case .thinking, .transcribing: return 44
        default: return 60
        }
    }

    @ViewBuilder private func headline(_ m: VoiceMode) -> some View {
        switch m {
        case .listening, .transcribing:
            if model.inputText.isEmpty {
                Text(m == .listening ? "tinglayapman…" : "tanib olyapman…").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Text(model.inputText).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.head)
            }
        case .thinking where !model.status.isEmpty:
            HStack(spacing: 7) {
                Image(systemName: serviceSymbol(model.status)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.hot)
                Text(model.status).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
            .id(model.status)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity.combined(with: .offset(y: -4))))
        default:
            Text(model.question.isEmpty ? "Orol" : model.question).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
    }

    @ViewBuilder private func controls(_ m: VoiceMode) -> some View {
        HStack(spacing: 6) {
            switch m {
            case .listening, .transcribing:
                if model.wokeByVoice {
                    Button("men emas") { model.onNotMe() }
                        .buttonStyle(PillButtonStyle())
                        .controlSize(.small)
                }
            case .thinking, .speaking:
                RoundControl(symbol: "mic.fill") { model.onBargeIn() }
                RoundControl(symbol: "stop.fill") { model.onStop() }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Approvals

struct ApprovalPanel: View {
    @ObservedObject var model: IslandModel
    var card: ApprovalCard
    @State private var picks: [String: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if card.questions.isEmpty { toolRequest } else { questions }
        }
        .padding(.horizontal, 15)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var toolRequest: some View {
        CardHeader(icon: card.dangerous ? "exclamationmark.triangle.fill" : "hand.raised.fill", title: card.title,
                   detail: card.project, tint: card.dangerous ? .orange : Palette.amber)
        if !card.detail.isEmpty {
            Text(card.detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
        }
        if card.dangerous {
            Label("Xavfli boʻlishi mumkin. Diqqat bilan tekshiring.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.orange)
        }
        HStack(spacing: 7) {
            Button("Rad etish") { model.onDecide(card, "deny", [:]) }.buttonStyle(PillButtonStyle())
            if !card.fromOrol {
                Button("Terminalda") { model.onDecide(card, "pass", [:]) }.buttonStyle(PillButtonStyle())
            }
            Spacer(minLength: 4)
            if card.canAlways {
                Button("Doim") { model.onDecide(card, "always", [:]) }.buttonStyle(PillButtonStyle())
            }
            Button("Ruxsat") { model.onDecide(card, "allow", [:]) }
                .buttonStyle(PillButtonStyle(primary: true, tint: card.dangerous ? .orange : Palette.amber))
        }
    }

    private var single: Bool { card.questions.count == 1 && !(card.questions.first?.multi ?? false) }

    private var complete: Bool { card.questions.allSatisfy { !(picks[$0.text] ?? []).isEmpty } }

    private func answers() -> [String: String] {
        var out: [String: String] = [:]
        for q in card.questions { out[q.text] = (picks[q.text] ?? []).joined(separator: ", ") }
        return out
    }

    private func toggle(_ q: Question, _ label: String) {
        var cur = picks[q.text] ?? []
        if q.multi {
            if let i = cur.firstIndex(of: label) { cur.remove(at: i) } else { cur.append(label) }
        } else {
            cur = [label]
        }
        picks[q.text] = cur
        if single { model.onDecide(card, "answers", answers()) }
    }

    @ViewBuilder private var questions: some View {
        FittedScroll(maxHeight: 250) { questionList }
        HStack(spacing: 7) {
            Button("Terminalda") { model.onDecide(card, "pass", [:]) }.buttonStyle(PillButtonStyle())
            Spacer()
            if !single {
                Button("Yuborish") { model.onDecide(card, "answers", answers()) }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .disabled(!complete)
                    .opacity(complete ? 1 : 0.4)
            }
        }
    }

    private var questionList: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(card.questions, id: \.text) { q in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(q.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(q.options, id: \.label) { o in
                            let on = (picks[q.text] ?? []).contains(o.label)
                            Button { toggle(q, o.label) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 12)).foregroundStyle(on ? emberColor : .white.opacity(0.4))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(o.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                                        if !o.detail.isEmpty {
                                            Text(o.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(on ? 0.13 : 0.06)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}


// MARK: - Claude as an upgrade: status and queue

struct ClaudeStatusLine: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let until = model.wakePausedUntil {
            HStack(spacing: 7) {
                Image(systemName: "ear.trianglebadge.exclamationmark").font(.system(size: 11, weight: .semibold))
                Text("“Hey Claude” \(friendlyTime(until)) gacha toʻxtatilgan").font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 0)
                Button("Davom ettirish") { model.onPauseListening(nil) }.buttonStyle(PillButtonStyle())
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 6)
        }
        if !model.claude.isReady {
            row(symbol: model.claude.symbol, text: model.claude.title + " · orolning oʻz buyruqlari ishlaydi",
                tint: .white.opacity(0.6))
        } else if let u = model.usage5h, u >= 0.5 {
            let week = model.usage7d.map { " · hafta \(Int(($0 * 100).rounded()))%" } ?? ""
            row(symbol: "gauge.with.dots.needle.67percent",
                text: "Claude limiti: 5 soat \(Int((u * 100).rounded()))%" + week,
                tint: u >= 0.85 ? .orange : .white.opacity(0.55))
        }
    }

    private func row(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 11.5)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
    }
}

struct QueueList: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.queue.suffix(4)) { item in QueueRow(item: item, model: model) }
        }
    }
}

struct QueueRow: View {
    var item: QueuedAsk
    @ObservedObject var model: IslandModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.answer == nil ? "clock" : "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.answer == nil ? .white.opacity(0.45) : emberColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(item.question).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(item.answer ?? (model.claude.isReady ? "Javob tayyorlanmoqda…" : "Claude qaytishini kutyapti"))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 4)
            IconButton(symbol: "xmark", size: 9) { model.onRemoveQueued(item) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover && item.answer != nil ? 0.09 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { if item.answer != nil { model.onOpenQueued(item) } }
        .onHover { hover = $0 }
    }
}


/// An icon for the tool Claude is using ("Google Calendar · list events" -> calendar).
func serviceSymbol(_ status: String) -> String {
    let t = status.lowercased()
    let map: [(String, String)] = [
        ("calendar", "calendar"), ("gmail", "envelope.fill"), ("mail", "envelope.fill"), ("notion", "doc.text.fill"),
        ("drive", "externaldrive.fill"), ("docs", "doc.richtext.fill"), ("sheets", "tablecells.fill"),
        ("telegram", "paperplane.fill"), ("spotify", "music.note"), ("youtube", "play.rectangle.fill"),
        ("instagram", "camera.fill"), ("github", "chevron.left.forwardslash.chevron.right"),
        ("firecrawl", "flame.fill"), ("internet", "globe"), ("web", "globe"), ("sahifa", "globe"),
        ("buyruq", "terminal.fill"), ("tahrir", "pencil"), ("yozish", "square.and.pencil"), ("oʻqish", "doc.fill"),
        ("qidiruv", "magnifyingglass"), ("agent", "person.2.fill"), ("qidiryapman", "magnifyingglass"),
    ]
    return map.first { t.contains($0.0) }?.1 ?? "sparkle"
}
