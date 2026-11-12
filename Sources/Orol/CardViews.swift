import SwiftUI

/// Rich answers in the assistant panel (after hey-claude's response widgets): open rows
/// with an "icon  Title · detail" header, separated by hairlines, no boxes.
struct CardView: View {
    @ObservedObject var model: IslandModel
    var card: CardKind

    var body: some View {
        Group {
            switch card {
            case .setting(let c): SettingCardView(card: c) { model.onUndo() }.id(c)
            case .system(let s): SystemCardView(sys: s, battery: model.battery, engines: model.engines)
            case .media:
                if let m = model.media {
                    VStack(spacing: 8) {
                        CardHeader(icon: "music.note", title: "Hozir", detail: m.appName)
                        MediaCard(model: model, media: m, boxed: false)
                    }
                }
            case .timers:
                VStack(spacing: 4) {
                    CardHeader(icon: "timer", title: "Taymerlar")
                    ForEach(model.timers) { t in TimerRow(timer: t) { model.onCancelTimer(t) } }
                }
            case .calendar(let title, let events): CalendarCardView(title: title, events: events)
            case .weather(let w): WeatherCardView(w: w)
            case .task(let sid):
                if let s = model.sessions.first(where: { $0.id == sid }) { TaskCardView(session: s) { model.onJump(s) } }
            case .route(let r): RouteCardView(r: r)
            case .place(let p): PlaceCardView(p: p)
            case .currency(let c): CurrencyCardView(c: c)
            case .code(let c): CodeCardView(c: c)
            case .translate(let c): TranslateCardView(c: c)
            case .define(let c): DefineCardView(c: c)
            case .news(let c): NewsCardView(c: c)
            case .link(let c): LinkCardView(c: c)
            case .deadlines(let c): DeadlinesCardView(c: c)
            case .timetable(let c): TimetableCardView(c: c)
            case .mail(let c): MailCardView(c: c)
            case .clip(let c): ClipCardView(c: c)
            case .image(let c): ImageCardView(c: c)
            case .units(let c): UnitCardView(c: c)
            case .draft(let c): DraftCardView(c: c).id(c.text)
            }
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
    }
}

/// "eski → yangi" with the arrow in ember.
func changeText(_ detail: String) -> Text {
    let parts = detail.components(separatedBy: " → ")
    guard parts.count == 2 else { return Text(detail) }
    return Text("\(Text(parts[0]).foregroundStyle(.white.opacity(0.55)))\(Text("  →  ").foregroundStyle(Palette.live))\(Text(parts[1]))")
}

struct SettingCardView: View {
    var card: SettingCard
    var undo: () -> Void
    @State private var start = Date()
    @State private var expired = false
    private let window = 12.0             // seconds the Undo stays offered

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: card.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.hot)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    changeText(card.detail).font(.system(size: 15.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white).contentTransition(.numericText())
                }
                Spacer(minLength: 6)
                if card.undoable && !expired {
                    Button("Qaytarish", action: undo).buttonStyle(UndoPillStyle()).transition(.opacity)
                }
            }
            if let l = card.level {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule().fill(LinearGradient(colors: [Palette.banked, Palette.hot], startPoint: .leading, endPoint: .trailing))
                            .frame(width: g.size.width * CGFloat(min(1, max(0, l))))
                        Circle().fill(.white).frame(width: 10, height: 10)
                            .offset(x: g.size.width * CGFloat(min(1, max(0, l))) - 5)
                    }
                }
                .frame(height: 10)
                .padding(.leading, 38)
            }
            if card.undoable && !expired {
                // how long the Undo stays: an ember line that burns down
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
                    let k = min(1, ctx.date.timeIntervalSince(start) / window)
                    GeometryReader { g in
                        Capsule().fill(Palette.live.opacity(0.85)).frame(width: g.size.width * CGFloat(1 - k), height: 2)
                    }
                }
                .frame(height: 2)
                .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(window))
            withAnimation(.easeOut(duration: 0.3)) { expired = true }
        }
    }
}

struct Ring: View {
    var value: Double
    var label: String
    var caption: String
    var tint: Color

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(min(1, max(0, value))))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(label).font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .frame(width: 48, height: 48)
            Text(caption).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.55))
        }
    }
}

/// A battery drawn in five cells, like the one in hey-claude's system widget.
struct BatteryGlyph: View {
    var percent: Int
    var charging: Bool

    var body: some View {
        let lit = Int((Double(percent) / 20).rounded(.up))
        let tint: Color = charging ? Palette.ok : (percent <= 20 ? Palette.bad : .white.opacity(0.9))
        HStack(spacing: 1.5) {
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(i < lit ? tint : Color.white.opacity(0.1))
                }
            }
            .padding(2.5)
            .frame(width: 42, height: 20)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.75), lineWidth: 1.4))
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.75)).frame(width: 2.5, height: 7)
        }
    }
}

struct Chip: View {
    var key: String
    var value: String
    var tint: Color = Palette.ok

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(key).foregroundStyle(.white.opacity(0.55))
            Text(value).foregroundStyle(.white.opacity(0.9))
        }
        .font(.system(size: 10.5, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 3.5)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

/// hey-claude's speedometer gauge: a 270° arc with a glowing value and tick dots.
struct ArcGauge: View {
    var value: Double
    var label: String
    var sub: String
    var caption: String
    var tint: Color
    var size: CGFloat = 76

    var body: some View {
        let v = CGFloat(min(1, max(0, value)))
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * v)
                .stroke(LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: tint.opacity(0.7), radius: 5)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: v)
            ForEach(0..<11, id: \.self) { i in
                Circle().fill(Color.white.opacity(Double(i) / 10 <= Double(v) ? 0.0 : 0.22)).frame(width: 2, height: 2)
                    .offset(y: -size / 2 - 7)
                    .rotationEffect(.degrees(-135 + 27 * Double(i)))
            }
            VStack(spacing: 0) {
                Text(label).font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .contentTransition(.numericText())
                if !sub.isEmpty { Text(sub).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.5)) }
            }
            Text(caption).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                .offset(y: size / 2 - 4)
        }
        .frame(width: size, height: size)
        // room for the stroke, the glow and the tick dots, which reach past the circle
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

/// A glowing bar (VRAM / RAM in hey-claude's system widget).
struct GlowBar: View {
    var title: String
    var text: String
    var value: Double
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(text).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.numericText())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(LinearGradient(colors: [tint.opacity(0.6), Palette.whiteHot], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, g.size.width * CGFloat(min(1, max(0, value)))))
                        .shadow(color: tint.opacity(0.8), radius: 4)
                }
            }
            .frame(height: 5)
        }
    }
}

struct SystemCardView: View {
    var sys: SystemCard
    var battery: BatteryInfo
    var engines: [(String, String)]

    var body: some View {
        let gb = 1_073_741_824.0
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(icon: "gearshape.fill", title: "Tizim")
            HStack(alignment: .center, spacing: 14) {
                if battery.present {
                    HStack(spacing: 12) {
                        BatteryGlyph(percent: battery.percent, charging: battery.charging || battery.plugged)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 1) {
                                Text("\(battery.percent)").font(.system(size: 26, weight: .bold).monospacedDigit())
                                    .contentTransition(.numericText())
                                Text("%").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                            }
                            .foregroundStyle(.white)
                            Text(battery.charging ? "quvvatlanmoqda" : (battery.plugged ? "ulangan" : "batareya"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(battery.charging || battery.plugged ? Palette.ok : .white.opacity(0.5))
                        }
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    ForEach(engines, id: \.0) { e in Chip(key: e.0, value: e.1) }
                }
            }
            HStack(alignment: .center, spacing: 16) {
                ArcGauge(value: sys.cpu, label: "\(Int((sys.cpu * 100).rounded()))%", sub: "\(sys.cores) yadro", caption: "CPU",
                         tint: sys.cpu > 0.8 ? .orange : Palette.amber)
                if let g = sys.gpu {
                    ArcGauge(value: g, label: "\(Int((g * 100).rounded()))%", sub: sys.thermal, caption: "GPU",
                             tint: g > 0.8 ? .orange : Palette.amber)
                }
                VStack(spacing: 16) {
                    GlowBar(title: "RAM", text: String(format: "%.1f / %.0f GB", sys.ramUsed / gb, sys.ramTotal / gb),
                            value: sys.ramUsed / max(1, sys.ramTotal), tint: Palette.hot)
                    GlowBar(title: "Disk", text: String(format: "%.0f GB boʻsh", sys.diskFree / 1e9),
                            value: (sys.diskTotal - sys.diskFree) / max(1, sys.diskTotal), tint: Palette.hot)
                }
            }
            Text("\(sys.chip) · ishlayapti \(Int(sys.uptime / 3600)) soat")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

// MARK: maps and money

func distanceText(_ m: Double) -> String {
    m >= 1000 ? String(format: m >= 10_000 ? "%.0f km" : "%.1f km", m / 1000) : "\(Int((m / 10).rounded()) * 10) m"
}

func durationText(_ s: TimeInterval) -> String {
    let min = Int((s / 60).rounded())
    if min < 60 { return "\(max(1, min)) daq" }
    return "\(min / 60) soat \(min % 60) daq"
}

/// A map image in the card's rounded inset (HIG: separate a block in an inset container).
struct MapImage: View {
    var image: NSImage?
    var height: CGFloat = 150
    var traffic = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.06)
                Image(systemName: "map").font(.system(size: 22)).foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            if traffic {
                HStack(spacing: 4) {
                    ForEach([Palette.ok, Palette.amber, Palette.bad], id: \.self) { Circle().fill($0).frame(width: 6, height: 6) }
                    Text("tirbandlik").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.72)))
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct RouteCardView: View {
    var r: RouteCard

    var body: some View {
        let tf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
        let how: (String, String) = r.mode == .walking ? ("piyoda", "figure.walk") : r.mode == .cycling ? ("velosipedda", "bicycle")
            : r.mode == .transit ? ("jamoat transporti", "bus.fill") : ("mashinada", "car.fill")
        VStack(alignment: .leading, spacing: 9) {
            CardHeader(icon: "mappin.and.ellipse", title: "Yoʻl", detail: r.dest)
            MapImage(image: r.map, traffic: r.traffic)
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(r.mode == .transit ? distanceText(r.meters) : durationText(r.seconds)).font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(r.mode == .transit ? "toʻgʻri chiziqda" : distanceText(r.meters)).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Label(how.0, systemImage: how.1).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Palette.hot))
                    if r.mode != .transit {
                        Text("yetib borasiz \(tf.string(from: r.arrive))").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            HStack(spacing: 6) {
                Text("\(r.origin == "siz" ? "Siz turgan joy" : r.origin) → \(r.dest) · \(r.source)")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer(minLength: 4)
                YandexButton(url: r.yandexURL, label: r.mode == .transit ? "Avtobus va metro" : "Yandex Xaritalar")
            }
        }
    }
}

struct PlaceCardView: View {
    var p: PlaceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CardHeader(icon: "mappin.circle.fill", title: "Joy", detail: p.name)
            MapImage(image: p.map, height: 130, traffic: p.traffic)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if !p.address.isEmpty { Text(p.address).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(2) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if !p.kind.isEmpty {
                        Text(p.kind).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.black.opacity(0.85))
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Palette.hot))
                    }
                    if let d = p.distance { Text(distanceText(d) + " uzoqda").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6)) }
                }
            }
            HStack { Spacer(); YandexButton(url: p.yandexURL, label: "Yandex Xaritalar") }
        }
    }
}

/// Opens the route or place in Yandex Maps (in the browser; traffic and public transport there).
struct YandexButton: View {
    var url: URL?
    var label: String

    var body: some View {
        Button { if let url { NSWorkspace.shared.open(url) } } label: {
            HStack(spacing: 5) {
                Text("Y").font(.system(size: 10, weight: .black)).foregroundStyle(.white)
                    .frame(width: 15, height: 15).background(Circle().fill(Color(hex: 0xFC3F1D)))
                Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.85))
                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.black.opacity(0.6))
            }
            .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color(hex: 0xFFCC00)))
        }
        .buttonStyle(PressDip())
    }
}

struct CurrencyCardView: View {
    var c: CurrencyCard

    var body: some View {
        let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "banknote.fill", title: "Valyuta", detail: "\(c.from) → \(c.to)")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Money.format(c.result, c.to)).font(.system(size: 30, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(c.to).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.leading, 23)
            Text("\(Money.format(c.amount, c.from)) \(c.from) × \(Money.format(c.rate, c.to))")
                .font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.75)).padding(.leading, 23)
            HStack {
                Text("1 \(c.from) = \(Money.format(c.rate, c.to)) \(c.to)")
                Spacer()
                Text("open.er-api.com · \(df.string(from: c.updated))")
            }
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).padding(.leading, 23)
        }
    }
}

struct CalendarCardView: View {
    var title: String
    var events: [CalEvent]

    var body: some View {
        let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "calendar", title: "Taqvim", detail: title)
            if events.isEmpty {
                Text("Hech narsa yoʻq").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7)).padding(.leading, 23)
            }
            ForEach(events.prefix(5)) { e in
                HStack(alignment: .top, spacing: 9) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(e.allDay ? "kun" : f.string(from: e.start)).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        if !e.allDay { Text(f.string(from: e.end)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.45)) }
                    }
                    .foregroundStyle(.white).frame(width: 38, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 1.5).fill(e.color).frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        if !e.place.isEmpty { Text(e.place).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                .opacity(e.end < Date() ? 0.45 : 1)
            }
            if events.count > 5 {
                Text("yana \(events.count - 5) ta").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).padding(.leading, 47)
            }
        }
    }
}

struct WeatherCardView: View {
    var w: WeatherCard

    var body: some View {
        let hf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH"; return f }()
        let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "uz_Latn_UZ"); f.dateFormat = "EEE"; return f }()
        let now = LocalData.weatherText(w.code)
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(icon: "location.fill", title: "Ob-havo", detail: w.place)
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: now.1).symbolRenderingMode(.multicolor).font(.system(size: 30))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int(w.temp.rounded()))°").font(.system(size: 28, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white).contentTransition(.numericText())
                    Text(now.0).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("his qilinadi \(Int(w.feels.rounded()))°")
                    Text(String(format: "shamol %.0f m/s", w.wind))
                }
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 0) {
                ForEach(w.hours, id: \.time) { h in
                    VStack(spacing: 4) {
                        Text(hf.string(from: h.time)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                        Image(systemName: LocalData.weatherText(h.code).1).symbolRenderingMode(.multicolor).font(.system(size: 13))
                        Text("\(Int(h.temp.rounded()))°").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                        Text(h.rain >= 20 ? "\(h.rain)%" : " ").font(.system(size: 9.5)).foregroundStyle(.cyan.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 8) {
                ForEach(w.days.dropFirst(), id: \.date) { d in
                    HStack(spacing: 5) {
                        Text(df.string(from: d.date)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        Image(systemName: LocalData.weatherText(d.code).1).symbolRenderingMode(.multicolor).font(.system(size: 11))
                        Text("\(Int(d.min.rounded()))…\(Int(d.max.rounded()))°").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct TaskCardView: View {
    var session: SessionInfo
    var jump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                CardHeader(icon: "checklist", title: "Vazifa", detail: session.project)
                Text(statusText).font(.system(size: 10, weight: .semibold)).foregroundStyle(statusTint)
                    .padding(.horizontal, 7).padding(.vertical, 2.5).background(Capsule().fill(statusTint.opacity(0.16)))
            }
            Text(session.prompt).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                .padding(.leading, 23)
            ForEach(Array(session.steps.suffix(4).enumerated()), id: \.offset) { i, step in
                let last = i == session.steps.suffix(4).count - 1 && session.status == .working
                HStack(spacing: 8) {
                    if last { OrbitEmber(count: 1).frame(width: 12, height: 12).scaleEffect(0.6) } else {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.ok.opacity(0.9)).frame(width: 12)
                    }
                    Text(step).font(.system(size: 11)).foregroundStyle(.white.opacity(last ? 0.9 : 0.55)).lineLimit(1)
                }
                .padding(.leading, 25)
            }
            if !session.summary.isEmpty && session.status != .working {
                Text(session.summary).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(2).padding(.leading, 23)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: jump)
    }

    private var statusText: String {
        switch session.status {
        case .working: return "ishlayapti"
        case .waiting: return "kutyapti"
        case .done: return "tugadi"
        case .failed: return "xato"
        case .idle: return "kutmoqda"
        }
    }
    private var statusTint: Color {
        switch session.status {
        case .working: return Palette.live
        case .waiting: return Palette.amber
        case .done: return Palette.ok
        case .failed: return Palette.bad
        case .idle: return .gray
        }
    }
}
