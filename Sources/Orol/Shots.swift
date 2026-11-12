import AppKit
import SwiftUI

/// Offscreen renders of every island state with made-up data, for checking the design
/// without a screen recording permission (after hey-claude's island_lab `--shots`).
enum Shots {
    private struct Stage: View {
        @ObservedObject var model: IslandModel
        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.33), Color(red: 0.42, green: 0.3, blue: 0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // the menu bar strip
                Rectangle().fill(Color.black.opacity(0.28)).frame(height: model.notch.height)
                IslandView(model: model)
                // where the hardware notch hides things
                if model.hasNotch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                        .stroke(Color.red.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: model.notch.width, height: model.notch.height)
                }
            }
        }
    }

    private static func base(notch: Bool = true) -> IslandModel {
        let m = IslandModel()
        m.hasNotch = notch
        m.notch = notch ? CGSize(width: 200, height: 38) : CGSize(width: 120, height: 26)
        m.battery = BatteryInfo(percent: 82, charging: false, plugged: false, present: true)
        m.hooksInstalled = true
        return m
    }

    private static func media() -> MediaInfo {
        MediaInfo(bundleId: "com.spotify.client", appName: "Spotify", title: "Tong otar chogʻi",
                  artist: "Namuna ijrochi", playing: true, duration: 214, position: 71)
    }

    private static func sessions() -> [SessionInfo] {
        var a = SessionInfo(id: "a", cwd: "/Users/me/Projects/Orol")
        a.status = .working; a.ticker = "Tahrir · Views.swift"; a.plus = 48; a.minus = 12
        a.turnStarted = Date().addingTimeInterval(-95); a.prompt = "orolga taymer qoʻsh"
        var b = SessionInfo(id: "b", cwd: "/Users/me/Projects/photo-app")
        b.status = .done; b.summary = "Veb-interfeys tayyor, testlar oʻtdi."
        var c = SessionInfo(id: "c", cwd: "/Users/me/Projects/homework")
        c.status = .waiting; c.isTask = true
        return [b, c, a]
    }

    static func states() -> [(String, IslandModel)] {
        var out: [(String, IslandModel)] = []
        func add(_ name: String, notch: Bool = true, _ f: (IslandModel) -> Void) {
            let m = base(notch: notch); f(m); out.append((name, m))
        }
        add("01-idle") { _ in }
        add("02-compact-media") { $0.media = media() }
        add("03-compact-session") { $0.sessions = [sessions()[2]] }
        add("04-compact-timer") { $0.timers = [TimerItem(label: "Taymer", end: Date().addingTimeInterval(272), total: 300)] }
        add("05-flash-charging") { $0.flash = Flash(icon: "bolt.fill", left: "Quvvatlanmoqda", right: "82%", tint: .green) }
        add("06-flash-done") { $0.flash = Flash(icon: "checkmark.circle.fill", left: "photo-app", right: "tugadi", tint: .green) }
        add("07-dashboard-empty") { $0.hovering = true; $0.hooksInstalled = false }
        add("08-dashboard-full") {
            $0.hovering = true; $0.media = media(); $0.sessions = sessions()
            $0.timers = [TimerItem(label: "Taymer", end: Date().addingTimeInterval(272), total: 300)]
        }
        add("09-input") { $0.phase = .input }
        add("10-listening") { $0.phase = .input; $0.micOn = true; $0.micLevel = 0.7; $0.inputText = "ertaga soat nechada darsim bor" }
        add("10b-listening-woke") { $0.phase = .input; $0.micOn = true; $0.micLevel = 0.7; $0.wokeByVoice = true }
        add("10c-transcribing") { $0.phase = .input; $0.transcribing = true; $0.inputText = "o'n besh foizi necha" }
        add("11-thinking") { $0.phase = .thinking; $0.question = "Notion’dagi oʻqish sahifamda nima bor?"; $0.status = "Notion · fetch" }
        add("11b-thinking-plain") { $0.phase = .thinking; $0.question = "sakson ning o'n besh foizi necha" }
        add("11c-speaking") {
            $0.phase = .done; $0.speaking = true; $0.question = "sakson ning o'n besh foizi necha"; $0.answer = "Saksonning 15 foizi 12."
        }
        add("23b-card-wifi") {
            $0.phase = .done; $0.question = "wi-fi ni yoq"; $0.answer = "Wi-Fi yoqildi."
            $0.card = .setting(SettingCard(icon: "wifi", title: "Wi-Fi", detail: "oʻchiq → yoqiq", level: nil, undoable: true))
        }
        add("23c-card-media") { $0.phase = .done; $0.question = "nima o'ynayapti"; $0.media = media(); $0.card = .media; $0.answer = "Spotify’da “Tong otar chogʻi”." }
        add("30-compact-two-media-timer") { $0.media = media(); $0.timers = [TimerItem(label: "Taymer", end: Date().addingTimeInterval(272), total: 600)] }
        add("31-compact-waiting") { $0.sessions = [sessions()[1]] }
        add("32-compact-three") { $0.media = media(); $0.sessions = [sessions()[2]]; $0.timers = [TimerItem(label: "Choy", end: Date().addingTimeInterval(95), total: 300)] }
        add("33-flash-airpods") { $0.flash = Flash(icon: "airpodspro", left: "AirPods Pro", right: "80% · 75%", tint: .white) }
        add("34-flash-silent") { $0.flash = Flash(icon: "bell.slash.fill", left: "Ovozsiz", right: "yoqildi", tint: Palette.bad) }
        add("12-answer") {
            $0.phase = .done; $0.question = "Oʻzbekiston poytaxti qayer?"
            $0.answer = "Oʻzbekistonning poytaxti Toshkent. U mamlakatning eng yirik shahri boʻlib, aholisi uch milliondan ortiq."
        }
        add("13-answer-long") {
            $0.phase = .done; $0.question = "Dynamic Island haqida batafsil aytib ber"
            $0.answer = Array(repeating: "Dynamic Island ekranning tepasidagi qora orolcha boʻlib, kerak boʻlganda kattalashadi va jonli maʼlumot koʻrsatadi.", count: 9).joined(separator: " ")
        }
        add("14-approval") {
            $0.approvals = [ApprovalCard(sessionId: "a", project: "Orol", tool: "Bash", title: "Buyruq",
                                         detail: "swift build -c release && ./build.sh", dangerous: false, canAlways: true)]
        }
        add("15-approval-danger") {
            $0.approvals = [ApprovalCard(sessionId: "a", project: "Orol", tool: "Bash", title: "Buyruq",
                                         detail: "rm -rf .build && git push --force origin main", dangerous: true, canAlways: false),
                            ApprovalCard(sessionId: "b", project: "x", tool: "Read", title: "Oʻqish", detail: "", dangerous: false, canAlways: false)]
        }
        add("16-question") {
            var c = ApprovalCard(sessionId: "a", project: "Orol", tool: "AskUserQuestion", title: "Savol", detail: "",
                                 dangerous: false, canAlways: false)
            c.questions = [Question(text: "Qaysi tilda ovozni tanishni yoqay?", header: "Til", options: [
                QuestionOption(label: "English", detail: "Qurilmaning oʻzida, internetsiz ishlaydi"),
                QuestionOption(label: "Русский", detail: "Internet kerak"),
                QuestionOption(label: "Hozircha kerak emas", detail: ""),
            ], multi: false)]
            $0.approvals = [c]
        }
        add("19-offline-dashboard") {
            $0.hovering = true; $0.claude = .offline; $0.online = false
            $0.queue = [QueuedAsk(question: "Notion’dagi oʻqish sahifamda nima bor?"),
                        QueuedAsk(question: "Ertangi ob-havo qanday?", answer: "Ertaga Toshkentda +12°, quyoshli.")]
        }
        add("20-limit-answer") {
            $0.claude = .limited(Date().addingTimeInterval(5400)); $0.phase = .done
            $0.question = "Bu hafta qanday yangiliklar boʻldi?"
            $0.answer = "Claude limiti tugadi. Savolingizni navbatga qoʻydim, Claude qaytishi bilan javob beraman."
        }
        add("21-usage") { $0.hovering = true; $0.usage5h = 0.88; $0.usage7d = 0.41 }
        add("22-compact-queue") { $0.queue = [QueuedAsk(question: "x", answer: "y")] }
        add("23-card-volume") {
            $0.phase = .done; $0.question = "ovozni o'ttizga"; $0.answer = "Ovoz 30%."
            $0.card = .setting(SettingCard(icon: "speaker.wave.2.fill", title: "Ovoz", detail: "30%", level: 0.3, undoable: true))
        }
        add("24-card-system") {
            $0.phase = .done; $0.question = "tizim holati"; $0.answer = "Protsessor 21%, xotira 11.2 / 16 GB, diskda 48 GB boʻsh."
            $0.battery = BatteryInfo(percent: 59, charging: true, plugged: true, present: true)
            $0.engines = [("tanish", "whisper uz"), ("ovoz", "mms uz")]
            $0.card = .system(SystemCard(cpu: 0.21, ramUsed: 11.2 * 1_073_741_824, ramTotal: 16 * 1_073_741_824,
                                         diskFree: 48e9, diskTotal: 494e9, thermal: "sovuq", uptime: 9 * 3600, chip: "Apple M2 Pro"))
        }
        add("25-card-calendar") {
            $0.phase = .done; $0.question = "bugun nima rejalarim bor"; $0.answer = "Bugun 4 ta tadbir. Eng yaqini: 13:00 da History."
            let d = Calendar.current.startOfDay(for: Date())
            func at(_ h: Double) -> Date { d.addingTimeInterval(h * 3600) }
            $0.card = .calendar(title: "Bugun", events: [
                CalEvent(start: at(9), end: at(10.5), title: "Mathematics", place: "B-304", allDay: false, color: .blue),
                CalEvent(start: at(13), end: at(14.5), title: "History", place: "A-210", allDay: false, color: .orange),
                CalEvent(start: at(15), end: at(16), title: "Study group", place: "", allDay: false, color: .green),
                CalEvent(start: at(19), end: at(20), title: "Sport zal", place: "Fitness", allDay: false, color: .pink)])
        }
        add("26-card-weather") {
            $0.phase = .done; $0.question = "ob-havo qanday"; $0.answer = "Toshkentda hozir 12°, qisman bulutli."
            let n = Date()
            $0.card = .weather(WeatherCard(place: "Toshkent", temp: 12.4, feels: 10.1, code: 2, wind: 3.2,
                hours: (0..<6).map { WeatherHour(time: n.addingTimeInterval(Double($0) * 3600), temp: 12 - Double($0) * 0.6, code: [2, 2, 3, 61, 61, 3][$0], rain: [0, 5, 20, 60, 70, 30][$0]) },
                days: (0..<3).map { WeatherDay(date: n.addingTimeInterval(Double($0) * 86400), min: 5 + Double($0), max: 14 - Double($0), code: [2, 61, 0][$0], rain: [10, 70, 0][$0]) }))
        }
        add("27-card-task") {
            var s = SessionInfo(id: "t", cwd: "/Users/me/Projects/Orol")
            s.status = .working; s.isTask = true; s.prompt = "README'ga oʻzbekcha ovoz boʻlimini qoʻsh"
            s.steps = ["Oʻqish · README.md", "Qidiruv · Whisper", "Tahrir · README.md"]
            $0.sessions = [s]; $0.phase = .done; $0.question = "vazifa orol: README'ni yangila"
            $0.answer = "“orol” loyihasida vazifa boshlandi."; $0.card = .task("t")
        }
        func card(_ name: String, _ q: String, _ a: String, _ c: CardKind) {
            add(name) { $0.phase = .done; $0.question = q; $0.answer = a; $0.card = c }
        }
        card("40-code", "pythonda fibonachchi", "Mana qisqa funksiya.", .code(CodeCard(lang: "python", file: "fib.py", code: """
        def fib(n: int) -> int:
            # iterativ usul
            a, b = 0, 1
            for _ in range(n):
                a, b = b, a + b
            return a

        print(fib(10))  # 55
        """)))
        card("41-translate", "ertaga uchrashamiz ni inglizchaga", "We’ll meet tomorrow.",
             .translate(TranslateCard(from: "uz", to: "en", source: "Ertaga uchrashamiz, soat beshda kutaman.", text: "See you tomorrow, I’ll be waiting at five.")))
        card("42-define", "serendipity ma'nosi", "Kutilmagan omad.", .define(DefineCard(word: "serendipity", phonetic: "ˌserənˈdipədē", pos: "noun",
             meanings: ["the occurrence of events by chance in a happy or beneficial way"], example: "a fortunate stroke of serendipity", source: "macOS lugʻati")))
        card("43-news", "yangiliklar", "Soʻnggi yangiliklar.", .news(NewsCard(topic: "Soʻnggi yangiliklar", items: [
            NewsItem(title: "Toshkentda BRT koridori qariyb 23 kilometrga uzayadi", source: "Kun.uz", time: Date().addingTimeInterval(-900), url: "https://kun.uz"),
            NewsItem(title: "Oʻzbekiston terma jamoasi navbatdagi oʻyinga tayyorlanmoqda", source: "Daryo", time: Date().addingTimeInterval(-3600), url: "https://daryo.uz"),
            NewsItem(title: "Dollar kursi biroz pasaydi", source: "Kun.uz", time: Date().addingTimeInterval(-7200), url: "https://kun.uz")])))
        card("44-link", "swiftui hujjati", "Apple’ning rasmiy sahifasi.", .link(LinkCard(title: "SwiftUI | Apple Developer Documentation",
             url: "https://developer.apple.com/documentation/swiftui", site: "Apple Developer", summary: "Declare the user interface and behavior for your app on every platform.")))
        card("45-deadlines", "muddatlarim", "3 ta muddat.", .deadlines(DeadlinesCard(items: [
            DeadlineItem(title: "Essay draft", due: Date().addingTimeInterval(5 * 3600), note: "Writing"),
            DeadlineItem(title: "Team project", due: Date().addingTimeInterval(2.5 * 86400), note: "Project"),
            DeadlineItem(title: "Quiz", due: Date().addingTimeInterval(9 * 86400), note: "Course")])))
        do {
            let d = Calendar.current.startOfDay(for: Date())
            func at(_ h: Double) -> Date { d.addingTimeInterval(h * 3600) }
            let nowH = Double(Calendar.current.component(.hour, from: Date()))
            card("46-timetable", "bugungi darslar", "Keyingi dars: Literature.", .timetable(TimetableCard(day: "Bugun", lessons: [
                CalEvent(start: at(nowH - 2), end: at(nowH - 0.5), title: "Mathematics", place: "B-304", allDay: false, color: .blue),
                CalEvent(start: at(nowH - 0.5), end: at(nowH + 1), title: "Physics", place: "A-210", allDay: false, color: .purple),
                CalEvent(start: at(nowH + 1.5), end: at(nowH + 3), title: "Literature", place: "C-101", allDay: false, color: .orange)])))
        }
        card("47-mail", "pochtam", "2 ta oʻqilmagan xat.", .mail(MailCard(account: "Gmail", unread: 2, items: [
            MailItem(from: "Course portal", subject: "New assignment posted", snippet: "Due Friday 23:59", time: Date().addingTimeInterval(-1200), unread: true),
            MailItem(from: "Newsletter", subject: "Weekly digest", snippet: "", time: Date().addingTimeInterval(-7200), unread: true),
            MailItem(from: "GitHub", subject: "[Orol] build passed", snippet: "", time: Date().addingTimeInterval(-86400), unread: false)])))
        card("48-clip", "buferda nima bor", "Buferda kod bor.", .clip(ClipCard(kind: "code", text: "let x = 42\nprint(\"salom\")\nfunc f() {}", image: nil, size: "38 belgi")))
        card("49-units", "10 km necha mil", "10 km = 6.214 mil.", .units(UnitCard(value: 10, from: "km", result: 6.2137, to: "mil")))
        card("50-draft", "azizga telegramda yoz", "Xabar tayyor.", .draft(DraftCard(app: "Telegram", to: "Aziz", text: "Ertaga soat 7 da uchrashamiz")))
        add("17-no-notch-idle", notch: false) { _ in }
        add("18-no-notch-dashboard", notch: false) { $0.hovering = true; $0.media = media(); $0.sessions = sessions() }
        return out
    }

    /// One offscreen render of a (possibly live) model.
    static func render(model: IslandModel, to url: URL) {
        let size = NSSize(width: 760, height: 660)
        let saved = model.pillSize
        let host = NSHostingView(rootView: Stage(model: model))
        host.sizingOptions = []
        host.safeAreaRegions = []
        let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        win.contentView = nil
        if saved != .zero && model.phase != .idle { model.pillSize = saved }
    }

    static func run(directory: String) {
        let dir = URL(fileURLWithPath: Paths.expand(directory))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = NSSize(width: 760, height: 660)
        for (name, model) in states() {
            Levels.shared.mic = name.contains("listen") ? 0.7 : 0
            Levels.shared.voiceMeter = name.contains("speak") ? { 0.6 } : nil
            let host = NSHostingView(rootView: Stage(model: model))
            host.sizingOptions = []
            host.safeAreaRegions = []
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: size),
                               styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            // let SwiftUI settle (preferences, ViewThatFits) before capturing
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let url = dir.appendingPathComponent(name + ".png")
                try? png.write(to: url)
                print("\(name)  pill \(Int(model.pillSize.width))x\(Int(model.pillSize.height))")
            }
            win.contentView = nil
        }
    }
}
