import AppKit
import SwiftUI

enum AssistantPhase: Equatable { case idle, input, thinking, answering, done }

enum Layout: Equatable { case idle, compact, flash, dashboard, assistant, approval }

struct MediaInfo: Equatable {
    var bundleId: String
    var appName: String
    var title: String
    var artist: String
    var playing: Bool
    var duration: Double?
    var position: Double?
    var positionAt = Date()
    var artwork: NSImage?
    var controllable = true          // false: only heard through CoreAudio (no track name, no controls)

    func currentPosition(at now: Date = Date()) -> Double? {
        guard let p = position else { return nil }
        let v = playing ? p + now.timeIntervalSince(positionAt) : p
        if let d = duration { return min(max(0, v), d) }
        return max(0, v)
    }
}

struct TimerItem: Identifiable, Equatable {
    let id = UUID()
    var label: String
    var end: Date
    var total: TimeInterval
}

enum SessionStatus: Equatable { case idle, working, waiting, done, failed }

struct SessionInfo: Identifiable, Equatable {
    let id: String
    var cwd: String
    var prompt = ""
    var ticker = ""
    var status: SessionStatus = .idle
    var started = Date()
    var lastEvent = Date()
    var turnStarted = Date()
    var termBundle = ""
    var entrypoint = ""
    var isTask = false
    var summary = ""
    var subagents = 0
    var plus = 0
    var minus = 0
    var steps: [String] = []     // the last few things it did, newest last

    var project: String {
        let n = (cwd as NSString).lastPathComponent
        return n.isEmpty ? "sessiya" : n
    }
}

struct QuestionOption: Equatable { var label: String; var detail: String }
struct Question: Equatable {
    var text: String
    var header: String
    var options: [QuestionOption]
    var multi: Bool
}

struct ApprovalCard: Identifiable, Equatable {
    let id = UUID()
    var sessionId: String
    var project: String
    var tool: String
    var title: String          // "Buyruq", "Tahrir · main.swift"
    var detail: String         // the command / path / arguments
    var dangerous: Bool
    var canAlways: Bool
    var questions: [Question] = []
    var created = Date()
    var fromOrol = false       // Orol's own agent or task asked
}

struct Flash: Identifiable, Equatable {
    var id = UUID()
    var icon: String           // SF Symbol
    var left: String
    var right: String
    var tint: Color = .white
}

struct BatteryInfo: Equatable {
    var percent = 100
    var charging = false
    var plugged = false
    var present = false
}

let emberColor = Color(red: 0.851, green: 0.467, blue: 0.341)   // Claude's terracotta

/// Whether Claude can answer right now. The island itself never depends on it.
enum ClaudeState: Equatable {
    case ready
    case offline                 // no network at all
    case limited(Date?)          // plan limit reached; when it resets, if known
    case noLogin
    case unreachable             // network is up but Claude didn't answer
    case missing                 // no `claude` CLI on this Mac

    var isReady: Bool { self == .ready }

    var symbol: String {
        switch self {
        case .ready: return "sparkle"
        case .offline: return "wifi.slash"
        case .limited: return "hourglass"
        case .noLogin: return "person.crop.circle.badge.exclamationmark"
        case .unreachable: return "exclamationmark.icloud"
        case .missing: return "questionmark.circle"
        }
    }

    var title: String {
        switch self {
        case .ready: return "Claude tayyor"
        case .offline: return "Internet yoʻq"
        case .limited(let d):
            if let d { return "Claude limiti tugadi · \(friendlyTime(d)) tiklanadi" }
            return "Claude limiti tugadi"
        case .noLogin: return "Claude hisobiga kirilmagan"
        case .unreachable: return "Claude javob bermayapti"
        case .missing: return "claude buyrugʻi topilmadi"
        }
    }
}

/// "17:30 da", "ertaga 09:00 da", "14-noyabr 09:00 da"
func friendlyTime(_ d: Date) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "uz_Latn_UZ")
    f.dateFormat = "HH:mm"
    if cal.isDateInToday(d) { return f.string(from: d) + " da" }
    if cal.isDateInTomorrow(d) { return "ertaga " + f.string(from: d) + " da" }
    f.dateFormat = "d-MMMM HH:mm"
    return f.string(from: d) + " da"
}

// MARK: cards: rich answers shown above the text (after hey-claude's widgets)

struct SettingCard: Hashable {
    var icon: String
    var title: String
    var detail: String
    var level: Double?           // 0...1 for a slider-like bar
    var undoable: Bool
}

struct SystemCard: Equatable {
    var cpu: Double              // 0...1
    var ramUsed: Double          // bytes
    var ramTotal: Double
    var diskFree: Double
    var diskTotal: Double
    var thermal: String
    var uptime: TimeInterval
    var chip: String
    var gpu: Double? = nil           // 0...1, Apple GPU utilization
    var cores = ProcessInfo.processInfo.activeProcessorCount
}

struct CalEvent: Equatable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date
    var title: String
    var place: String
    var allDay: Bool
    var color: Color
}

struct WeatherHour: Equatable { var time: Date; var temp: Double; var code: Int; var rain: Int }
struct WeatherDay: Equatable { var date: Date; var min: Double; var max: Double; var code: Int; var rain: Int }
struct WeatherCard: Equatable {
    var place: String
    var temp: Double
    var feels: Double
    var code: Int
    var wind: Double
    var hours: [WeatherHour]
    var days: [WeatherDay]
}

enum CardKind: Equatable {
    case setting(SettingCard)
    case system(SystemCard)
    case media
    case timers
    case calendar(title: String, events: [CalEvent])
    case weather(WeatherCard)
    case task(String)            // session id
    case route(RouteCard)
    case place(PlaceCard)
    case currency(CurrencyCard)
    case code(CodeCard)
    case translate(TranslateCard)
    case define(DefineCard)
    case news(NewsCard)
    case link(LinkCard)
    case deadlines(DeadlinesCard)
    case timetable(TimetableCard)
    case mail(MailCard)
    case clip(ClipCard)
    case image(ImageCard)
    case units(UnitCard)
    case draft(DraftCard)

    /// Cards of the same kind replace each other in the stack; different ones pile up.
    var kindKey: String {
        switch self {
        case .setting(let c): return "setting-" + c.title
        case .system: return "system"
        case .media: return "media"
        case .timers: return "timers"
        case .calendar: return "calendar"
        case .weather: return "weather"
        case .task(let s): return "task-" + s
        case .route: return "route"
        case .place: return "place"
        case .currency: return "currency"
        case .code(let c): return "code-" + String(c.code.hashValue)
        case .translate: return "translate"
        case .define: return "define"
        case .news: return "news"
        case .link(let l): return "link-" + l.url
        case .deadlines: return "deadlines"
        case .timetable: return "timetable"
        case .mail: return "mail"
        case .clip: return "clip"
        case .image(let i): return "image-" + i.path
        case .units: return "units"
        case .draft: return "draft"
        }
    }
}

/// A question asked while Claude was away; answered in the background when it returns.
struct QueuedAsk: Identifiable, Codable, Equatable {
    var id = UUID()
    var question: String
    var answer: String?
    var asked = Date()
    var answered: Date?
}

final class IslandModel: ObservableObject {
    // Geometry of the hardware notch (or a stand-in pill on screens without one).
    @Published var notch = CGSize(width: 190, height: 32)
    @Published var hasNotch = true

    @Published var hovering = false

    // Assistant
    @Published var phase: AssistantPhase = .idle
    @Published var inputText = ""
    @Published var question = ""
    @Published var answer = ""
    @Published var status = ""
    @Published var micOn = false
    @Published var micLevel: CGFloat = 0
    @Published var micNote = ""
    @Published var transcribing = false
    /// Rich answers stacked in the open panel (newest last, at most three), like hey-claude.
    @Published var cards: [CardKind] = []
    /// The newest card. Setting one adds it to the stack (replacing one of the same kind);
    /// nil clears the stack.
    var card: CardKind? {
        get { cards.last }
        set {
            guard let c = newValue else { cards = []; return }
            var list = cards.filter { $0.kindKey != c.kindKey }
            list.append(c)
            cards = Array(list.suffix(3))
        }
    }
    // "Hey Claude"
    @Published var wakeAvailable = false
    @Published var wakeListening = false
    @Published var wakePausedUntil: Date?
    @Published var wokeByVoice = false
    @Published var speaking = false
    @Published var focusToken = 0

    // Live activities
    @Published var sessions: [SessionInfo] = []
    @Published var approvals: [ApprovalCard] = []
    @Published var media: MediaInfo?
    @Published var timers: [TimerItem] = []
    @Published var battery = BatteryInfo()
    @Published var flash: Flash?
    @Published var hooksInstalled = false

    // Claude, as an upgrade on top of the island
    @Published var claude: ClaudeState = .ready
    @Published var online = true
    @Published var usage5h: Double?
    @Published var usage7d: Double?
    @Published var queue: [QueuedAsk] = []
    @Published var hotkeyLabel = "⌃⌥Space"
    /// What hears and speaks ("tanish" → "whisper uz"), shown as chips on the system card.
    var engines: [(String, String)] = []

    /// The pill's current layout size, reported by the view; the window uses it for hit testing.
    var pillSize = CGSize(width: 190, height: 32)
    /// The pill moves sideways when one side is wider (minimal + detached bubble), and the
    /// bubble sticks out to the right of it; the window needs both for hit testing.
    var pillOffset: CGFloat = 0
    var bubbleWidth: CGFloat = 0

    // Actions, wired by the app.
    var onSubmit: (String, Bool) -> Void = { _, _ in }
    var onOpenInput: (Bool) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onToggleMic: () -> Void = {}
    var onStop: () -> Void = {}
    var onDecide: (ApprovalCard, String, [String: String]) -> Void = { _, _, _ in }
    var onMedia: (String) -> Void = { _ in }
    var onJump: (SessionInfo) -> Void = { _ in }
    var onCancelTimer: (TimerItem) -> Void = { _ in }
    var onInstallHooks: () -> Void = {}
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onOpenQueued: (QueuedAsk) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onPauseListening: (TimeInterval?) -> Void = { _ in }    // nil = resume
    var onNotMe: () -> Void = {}
    var onBargeIn: () -> Void = {}
    var onOpenActivity: (LiveActivity?) -> Void = { _ in }     // a tap on the compact island             // the mic button while Claude thinks or talks
    var onRemoveQueued: (QueuedAsk) -> Void = { _ in }

    var answeredQueue: [QueuedAsk] { queue.filter { $0.answer != nil } }
    var waitingQueue: [QueuedAsk] { queue.filter { $0.answer == nil } }

    var workingSessions: [SessionInfo] { sessions.filter { $0.status == .working || $0.status == .waiting } }

    var hasActivity: Bool {
        (media?.playing ?? false) || !timers.isEmpty || !workingSessions.isEmpty || !answeredQueue.isEmpty
    }

    var layout: Layout {
        if !approvals.isEmpty { return .approval }
        if phase != .idle { return .assistant }
        if hovering { return .dashboard }
        if flash != nil { return .flash }
        if hasActivity { return .compact }
        return .idle
    }

    private var flashWork: DispatchWorkItem?

    func showFlash(_ f: Flash, seconds: Double = 3.2) {
        flashWork?.cancel()
        flash = f
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.flash?.id == f.id else { return }
            self.flash = nil
        }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}

func formatClock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.up)))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}
