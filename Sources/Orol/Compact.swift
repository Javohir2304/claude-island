import AppKit
import SwiftUI

// The island at rest, after iPhone's Dynamic Island (HIG › Live Activities):
// - one activity: the compact presentation, a leading and a trailing view snug against the
//   camera (here the notch) that read as one piece of information;
// - two or more: the most relevant one stays attached in its minimal form, the next one
//   appears detached beside the island as a small circle or oval;
// - a thin key line in the activity's colour keeps it visible on a dark menu bar.

enum LiveActivity: Equatable {
    case waiting(SessionInfo)            // Claude needs you
    case timer(TimerItem)
    case working([SessionInfo])
    case media(MediaInfo)
    case answers(Int)                    // queued questions answered while you were away

    var id: String {
        switch self {
        case .waiting: return "waiting"
        case .timer(let t): return "timer-\(t.id)"
        case .working: return "working"
        case .media(let m): return "media-\(m.bundleId)"
        case .answers: return "answers"
        }
    }
}

extension IslandModel {
    /// Ongoing activities, most relevant first.
    var activities: [LiveActivity] {
        var out: [LiveActivity] = []
        if let w = sessions.first(where: { $0.status == .waiting }) { out.append(.waiting(w)) }
        if let t = timers.min(by: { $0.end < $1.end }) { out.append(.timer(t)) }
        let working = sessions.filter { $0.status == .working }
        if !working.isEmpty { out.append(.working(working)) }
        if let m = media, m.playing { out.append(.media(m)) }
        if !answeredQueue.isEmpty { out.append(.answers(answeredQueue.count)) }
        return out
    }
}

/// The average colour of an image (the artwork tints the bars and the key line, as on iPhone).
enum ArtTint {
    private static var cache: [ObjectIdentifier: Color] = [:]

    static func color(_ image: NSImage?) -> Color? {
        guard let image else { return nil }
        if let c = cache[ObjectIdentifier(image)] { return c }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        // lift dark covers so the colour still reads on black
        var (r, g, b) = (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
        let maxc = max(r, g, b, 0.001)
        if maxc < 0.6 { let k = 0.75 / maxc; r = min(1, r * k); g = min(1, g * k); b = min(1, b * k) }
        let c = Color(.sRGB, red: r, green: g, blue: b)
        if cache.count > 40 { cache.removeAll() }
        cache[ObjectIdentifier(image)] = c
        return c
    }
}

func activityTint(_ a: LiveActivity) -> Color {
    switch a {
    case .waiting: return Palette.amber
    case .timer: return Palette.hot
    case .working: return Palette.live
    case .media(let m): return ArtTint.color(m.artwork) ?? Palette.hot
    case .answers: return Palette.live
    }
}

/// Compact leading view: the activity's mark.
struct CompactLeading: View {
    var activity: LiveActivity

    var body: some View {
        Group {
            switch activity {
            case .waiting:
                Image(systemName: "hand.raised.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.amber)
                    .symbolEffect(.pulse, options: .repeating)
            case .timer(let t):
                TimerRing(timer: t, size: 18)
            case .working(let s):
                OrbitEmber(count: s.count)
            case .media(let m):
                Artwork(image: m.artwork, size: 21)
            case .answers:
                Image(systemName: "tray.full.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.live)
            }
        }
        .frame(height: 22)
    }
}

/// Compact trailing view: the live value.
struct CompactTrailing: View {
    var activity: LiveActivity

    var body: some View {
        Group {
            switch activity {
            case .waiting(let s):
                Text(s.project).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.amber).lineLimit(1)
            case .timer(let t):
                Countdown(end: t.end).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.hot)
            case .working(let s):
                if s.count > 1 {
                    Text("\(s.count)").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                } else if let first = s.first {
                    Elapsed(since: first.turnStarted, tint: Palette.hot).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                }
            case .media(let m):
                AudioBars(playing: m.playing, color: ArtTint.color(m.artwork) ?? .white)
            case .answers(let n):
                Text("\(n)").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
            }
        }
        .frame(height: 22)
    }
}

/// The detached minimal presentation: a circle, or an oval when it carries a number.
struct MinimalBubble: View {
    var activity: LiveActivity
    var height: CGFloat

    var body: some View {
        let tint = activityTint(activity)
        Group {
            switch activity {
            case .timer(let t):
                HStack(spacing: 4) {
                    TimerRing(timer: t, size: 13)
                    Countdown(end: t.end).font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.hot)
                }
                .padding(.horizontal, 9)
            case .media(let m):
                Artwork(image: m.artwork, size: height - 10).clipShape(Circle())
            default:
                CompactLeading(activity: activity).scaleEffect(0.9)
            }
        }
        .frame(minWidth: height, minHeight: height, maxHeight: height)
        .background(RoundedRectangle(cornerRadius: height / 2, style: .circular).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: height / 2, style: .circular).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: height / 2, style: .circular))
    }
}

/// A countdown ring that empties as the timer runs out.
struct TimerRing: View {
    var timer: TimerItem
    var size: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let left = max(0, timer.end.timeIntervalSince(ctx.date)) / max(1, timer.total)
            ZStack {
                Circle().stroke(Palette.hot.opacity(0.25), lineWidth: 2.4)
                Circle().trim(from: 0, to: CGFloat(left)).stroke(Palette.hot, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: left)
            }
            .frame(width: size, height: size)
        }
    }
}
