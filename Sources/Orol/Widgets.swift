import AppKit
import CoreServices
import EventKit
import SwiftUI

// The rest of hey-claude's widgets, rebuilt for the Mac: code, translate, define, news, link,
// deadlines, timetable, email, clipboard, image, units and a Telegram draft. Local ones come
// from the Mac itself (pasteboard, Dictionary, Calendar/Reminders, Mail, RSS); the others come
// from Claude, which may append a ```orol {json}``` block to its answer.

struct CodeCard: Equatable { var lang: String; var file: String; var code: String }
struct TranslateCard: Equatable { var from: String; var to: String; var source: String; var text: String }
struct DefineCard: Equatable { var word: String; var phonetic: String; var pos: String; var meanings: [String]; var example: String; var source: String }
struct NewsItem: Equatable { var title: String; var source: String; var time: Date?; var url: String }
struct NewsCard: Equatable { var topic: String; var items: [NewsItem] }
struct LinkCard: Equatable { var title: String; var url: String; var site: String; var summary: String }
struct DeadlineItem: Equatable { var title: String; var due: Date; var note: String }
struct DeadlinesCard: Equatable { var items: [DeadlineItem] }
struct MailItem: Equatable { var from: String; var subject: String; var snippet: String; var time: Date?; var unread: Bool }
struct MailCard: Equatable { var account: String; var unread: Int; var items: [MailItem] }
struct ClipCard: Equatable { var kind: String; var text: String; var image: NSImage?; var size: String }
struct ImageCard: Equatable { var title: String; var image: NSImage; var path: String }
struct UnitCard: Equatable { var value: Double; var from: String; var result: Double; var to: String }
struct TimetableCard: Equatable { var day: String; var lessons: [CalEvent] }
struct DraftCard: Equatable { var app: String; var to: String; var text: String }

// MARK: - Claude's cards

enum CardParse {
    /// Splits an answer into what is shown/spoken and the cards it carries: ```orol {json}```
    /// blocks and code fences. A block still streaming in is hidden.
    static func split(_ text: String) -> (String, [CardKind]) {
        var spoken = text
        var cards: [CardKind] = []
        while let open = spoken.range(of: "```") {
            let afterTicks = spoken[open.upperBound...]
            let headerEnd = afterTicks.firstIndex(of: "\n") ?? afterTicks.endIndex
            let lang = afterTicks[..<headerEnd].trimmingCharacters(in: .whitespaces).lowercased()
            guard headerEnd < afterTicks.endIndex,
                  let close = spoken.range(of: "```", range: spoken.index(after: headerEnd)..<spoken.endIndex) else {
                spoken = String(spoken[..<open.lowerBound])          // unfinished: hide until it's complete
                break
            }
            let body = String(spoken[spoken.index(after: headerEnd)..<close.lowerBound])
            if lang == "orol" || lang == "orol-card" {
                if let c = card(fromJSON: body) { cards.append(c) }
            } else {
                let parts = lang.split(separator: " ", maxSplits: 1).map(String.init)
                cards.append(.code(CodeCard(lang: parts.first ?? "", file: parts.count > 1 ? parts[1] : "",
                                            code: body.trimmingCharacters(in: .newlines))))
            }
            spoken.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let clean = spoken.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, cards)
    }

    private static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func card(fromJSON s: String) -> CardKind? {
        guard let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let kind = (j["kind"] ?? j["card"]) as? String else { return nil }
        func str(_ k: String) -> String { (j[k] as? String) ?? "" }
        let items = (j["items"] as? [[String: Any]]) ?? []
        switch kind {
        case "translate":
            return .translate(TranslateCard(from: str("from"), to: str("to"), source: str("source"), text: str("text")))
        case "define":
            return .define(DefineCard(word: str("word"), phonetic: str("phonetic"), pos: str("pos"),
                                      meanings: (j["meanings"] as? [String]) ?? [], example: str("example"), source: "Claude"))
        case "news":
            return .news(NewsCard(topic: str("topic"), items: items.prefix(5).map {
                NewsItem(title: $0["title"] as? String ?? "", source: $0["source"] as? String ?? "",
                         time: date($0["time"] as? String), url: $0["url"] as? String ?? "")
            }))
        case "link":
            return .link(LinkCard(title: str("title"), url: str("url"), site: str("site"), summary: str("summary")))
        case "code":
            return .code(CodeCard(lang: str("lang"), file: str("file"), code: str("code")))
        case "deadlines":
            let list = items.compactMap { i -> DeadlineItem? in
                guard let due = date(i["due"] as? String) else { return nil }
                return DeadlineItem(title: i["title"] as? String ?? "", due: due, note: i["note"] as? String ?? "")
            }
            return list.isEmpty ? nil : .deadlines(DeadlinesCard(items: list.sorted { $0.due < $1.due }))
        case "email":
            return .mail(MailCard(account: str("account"), unread: j["unread"] as? Int ?? 0, items: items.prefix(5).map {
                MailItem(from: $0["from"] as? String ?? "", subject: $0["subject"] as? String ?? "",
                         snippet: $0["snippet"] as? String ?? "", time: date($0["time"] as? String),
                         unread: $0["unread"] as? Bool ?? false)
            }))
        default:
            return nil
        }
    }

    /// Appended to Claude's system prompts.
    static let prompt = """
    When a card would show the answer better, keep your sentences short and append exactly one \
    block at the very end, fenced as ```orol and containing one JSON object. Kinds: \
    {"kind":"translate","from":"uz","to":"en","source":"…","text":"…"}; \
    {"kind":"define","word":"…","phonetic":"…","pos":"noun","meanings":["…"],"example":"…"}; \
    {"kind":"news","topic":"…","items":[{"title":"…","source":"…","time":"ISO-8601","url":"…"}]} (at most 5); \
    {"kind":"link","title":"…","url":"…","site":"…","summary":"…"}; \
    {"kind":"deadlines","items":[{"title":"…","due":"ISO-8601","note":"…"}]}; \
    {"kind":"email","account":"…","unread":3,"items":[{"from":"…","subject":"…","snippet":"…","time":"ISO-8601","unread":true}]}. \
    Put code in a normal fenced code block (```swift file.swift) instead of the text. The block is \
    drawn as a card and never read aloud, so don't repeat its content in your sentences.
    """
}

// MARK: - Local sources

enum LocalWidgets {
    // clipboard
    static func clipboard() -> ClipCard? {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb), pb.types?.contains(where: { $0 == .png || $0 == .tiff }) == true {
            return ClipCard(kind: "image", text: "", image: img, size: "\(Int(img.size.width))×\(Int(img.size.height))")
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first {
            return ClipCard(kind: "file", text: urls.count > 1 ? "\(u.lastPathComponent) va yana \(urls.count - 1) ta" : u.path,
                            image: NSWorkspace.shared.icon(forFile: u.path), size: "\(urls.count) ta fayl")
        }
        guard let s = pb.string(forType: .string), !s.isEmpty else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: String
        if t.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil { kind = "url" }
        else if t.contains("\n") && (t.contains("{") || t.contains("func ") || t.contains("def ") || t.contains(";") || t.contains("import ")) { kind = "code" }
        else { kind = "text" }
        return ClipCard(kind: kind, text: s, image: nil, size: "\(s.count) belgi")
    }

    // screenshot (macOS asks once for Screen Recording)
    static func screenshot(_ done: @escaping (ImageCard?) -> Void) {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Orol")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Skrinshot \(f.string(from: Date())).png")
        DispatchQueue.global(qos: .userInitiated).async {
            LocalData.run("/usr/sbin/screencapture", ["-x", url.path])
            let img = NSImage(contentsOf: url)
            DispatchQueue.main.async { done(img.map { ImageCard(title: "Skrinshot", image: $0, path: url.path) }) }
        }
    }

    // news from Uzbek RSS feeds
    static func news(_ done: @escaping (NewsCard?) -> Void) {
        let feeds = [("Kun.uz", "https://kun.uz/news/rss"), ("Daryo", "https://daryo.uz/feed")]
        let group = DispatchGroup()
        var all: [NewsItem] = []
        let lock = NSLock()
        for (name, s) in feeds {
            guard let url = URL(string: s) else { continue }
            group.enter()
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("Mozilla/5.0 Orol", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, _, _ in
                defer { group.leave() }
                guard let data else { return }
                let items = RSS.parse(data, source: name)
                lock.lock(); all += items.prefix(6); lock.unlock()
            }.resume()
        }
        group.notify(queue: .main) {
            let sorted = all.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
            done(sorted.isEmpty ? nil : NewsCard(topic: "Soʻnggi yangiliklar", items: Array(sorted.prefix(5))))
        }
    }

    // deadlines: Reminders with a due date, and calendar events that look like deadlines
    static func deadlines(_ done: @escaping (DeadlinesCard?, String?) -> Void) {
        let store = EKEventStore()
        store.requestFullAccessToReminders { ok, _ in
            var items: [DeadlineItem] = []
            let finish = {
                let cal = EKEventStore()
                cal.requestFullAccessToEvents { ok2, _ in
                    if ok2 {
                        let words = ["deadline", "dedlayn", "muddat", "topshir", "submit", "due", "homework", "hw", "imtihon", "exam", "quiz", "project"]
                        let pred = cal.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(21 * 86400), calendars: nil)
                        for e in cal.events(matching: pred) where words.contains(where: { (e.title ?? "").lowercased().contains($0) }) {
                            items.append(DeadlineItem(title: e.title ?? "", due: e.startDate, note: e.calendar.title))
                        }
                    }
                    DispatchQueue.main.async {
                        let list = items.sorted { $0.due < $1.due }
                        if list.isEmpty && !ok && !ok2 { done(nil, "Eslatmalar va Kalendarga ruxsat kerak: System Settings → Privacy & Security."); return }
                        done(list.isEmpty ? nil : DeadlinesCard(items: Array(list.prefix(6))), nil)
                    }
                }
            }
            guard ok else { finish(); return }
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: Date().addingTimeInterval(30 * 86400), calendars: nil)
            store.fetchReminders(matching: pred) { rs in
                for r in rs ?? [] {
                    guard let comps = r.dueDateComponents, let due = Calendar.current.date(from: comps) else { continue }
                    items.append(DeadlineItem(title: r.title ?? "", due: due, note: r.calendar.title))
                }
                finish()
            }
        }
    }

    // Mail.app (only when it's already running, so asking never launches it)
    static func mail(_ done: @escaping (MailCard?) -> Void) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first != nil else { done(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let src = """
            tell application "Mail"
                set out to ""
                set n to unread count of inbox
                set msgs to messages 1 thru (count of messages of inbox) of inbox
                set i to 0
                repeat with m in msgs
                    set i to i + 1
                    if i > 5 then exit repeat
                    set out to out & (sender of m) & "\\t" & (subject of m) & "\\t" & ((read status of m) as string) & "\\n"
                end repeat
                return (n as string) & "\\n" & out
            end tell
            """
            var err: NSDictionary?
            let r = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue
            let lines = (r ?? "").split(separator: "\n").map(String.init)
            let card: MailCard? = lines.isEmpty ? nil : MailCard(account: "Mail", unread: Int(lines[0]) ?? 0, items: lines.dropFirst().map { l in
                let p = l.components(separatedBy: "\t")
                let from = (p.first ?? "").replacingOccurrences(of: #"\s*<.*>"#, with: "", options: .regularExpression)
                return MailItem(from: from, subject: p.count > 1 ? p[1] : "", snippet: "", time: nil, unread: p.count > 2 && p[2] == "false")
            })
            DispatchQueue.main.async { done(card) }
        }
    }

    // macOS's Dictionary (offline)
    static func define(_ word: String) -> DefineCard? {
        let range = CFRange(location: 0, length: word.utf16.count)
        guard let def = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?, !def.isEmpty else { return nil }
        // "word | fəˈnetɪk | noun 1 first meaning. 2 second meaning: example."
        var text = def
        var phonetic = ""
        if let a = text.firstIndex(of: "|"), let b = text[text.index(after: a)...].firstIndex(of: "|") {
            phonetic = text[text.index(after: a)..<b].trimmingCharacters(in: .whitespaces)
            text = String(text[text.index(after: b)...])
        }
        let posWords = ["noun", "verb", "adjective", "adverb", "pronoun", "preposition", "conjunction", "exclamation"]
        var pos = ""
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let w = posWords.first(where: { trimmed.hasPrefix($0) }) { pos = w; text = String(trimmed.dropFirst(w.count)) }
        var meanings = text.components(separatedBy: CharacterSet(charactersIn: "•")).flatMap {
            $0.split(separator: #/\s\d+\s/#).map(String.init)
        }
        meanings = meanings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count > 3 }
        var example = ""
        if let first = meanings.first, let colon = first.firstIndex(of: ":") {
            example = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            meanings[0] = String(first[..<colon])
        }
        return DefineCard(word: word, phonetic: phonetic, pos: pos, meanings: Array(meanings.prefix(3)),
                          example: String(example.prefix(140)), source: "macOS lugʻati")
    }
}

/// A tiny RSS reader (title, link, pubDate).
final class RSS: NSObject, XMLParserDelegate {
    private var items: [NewsItem] = []
    private var cur: [String: String]?
    private var key = ""
    private var text = ""
    private let source: String

    private init(source: String) { self.source = source }

    static func parse(_ data: Data, source: String) -> [NewsItem] {
        let r = RSS(source: source)
        let p = XMLParser(data: data)
        p.delegate = r
        p.parse()
        return r.items
    }

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" { cur = [:] }
        key = name
        text = ""
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ p: XMLParser, foundCDATA d: Data) { text += String(data: d, encoding: .utf8) ?? "" }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "item", let c = cur {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            items.append(NewsItem(title: c["title"] ?? "", source: source, time: c["pubDate"].flatMap { f.date(from: $0) }, url: c["link"] ?? ""))
            cur = nil
        } else if cur != nil, ["title", "link", "pubDate"].contains(name) {
            cur?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Views

/// A letter tile for a source or a person: the colour comes from the name.
struct LetterTile: View {
    var name: String
    var size: CGFloat = 26

    var body: some View {
        let palette: [Color] = [Palette.live, Color(hex: 0x5B8DEF), Color(hex: 0x4FB286), Color(hex: 0xB36AE2), Palette.amber, Color(hex: 0xE2667A)]
        let h = abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) })
        let letters = String(name.split(separator: " ").prefix(2).compactMap { $0.first }).uppercased()
        Text(letters.isEmpty ? "?" : letters)
            .font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [palette[h % palette.count], palette[h % palette.count].opacity(0.6)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}

/// A small action pill with a confirmation flash ("Nusxa" → "Olindi ✓").
struct ActionPill: View {
    var title: String
    var icon: String
    var done: String = ""
    var action: () -> Void
    @State private var flashed = false

    var body: some View {
        Button {
            action()
            guard !done.isEmpty else { return }
            withAnimation(.snappy) { flashed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(.snappy) { flashed = false } }
        } label: {
            Label(flashed ? done : title, systemImage: flashed ? "checkmark" : icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(flashed ? Palette.ok : .white.opacity(0.9))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressDip())
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func relativeTime(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = Date().timeIntervalSince(d)
    if s < 60 { return "hozir" }
    if s < 3600 { return "\(Int(s / 60)) daq oldin" }
    if s < 86400 { return "\(Int(s / 3600)) soat oldin" }
    let f = DateFormatter(); f.dateFormat = "d MMM"; return f.string(from: d)
}

// code

enum Syntax {
    static let keywords: Set<String> = ["func", "let", "var", "if", "else", "for", "while", "return", "import", "class", "struct",
        "enum", "case", "switch", "guard", "def", "in", "from", "as", "try", "catch", "except", "public", "private", "static",
        "const", "function", "async", "await", "new", "true", "false", "nil", "None", "null", "self", "this", "int", "void",
        "include", "lambda", "yield", "break", "continue", "pass", "elif", "with", "and", "or", "not", "is", "throw", "throws"]

    static func line(_ s: String) -> Text {
        if let c = s.range(of: #"(//|#).*$"#, options: .regularExpression), !s[..<c.lowerBound].contains("\"") {
            return Text("\(line(String(s[..<c.lowerBound])))\(Text(s[c]).foregroundStyle(.white.opacity(0.35)))")
        }
        var out = Text("")
        var token = ""
        var inString: Character?
        func flush() {
            guard !token.isEmpty else { return }
            let t: Text
            if inString != nil { t = Text(token).foregroundStyle(Color(hex: 0xA8D58F)) }
            else if keywords.contains(token) { t = Text(token).foregroundStyle(Palette.hot).bold() }
            else if Double(token) != nil { t = Text(token).foregroundStyle(Palette.amber) }
            else if token.first?.isUppercase == true { t = Text(token).foregroundStyle(Color(hex: 0x8FC1F2)) }
            else { t = Text(token).foregroundStyle(.white.opacity(0.88)) }
            out = Text("\(out)\(t)")
            token = ""
        }
        for ch in s {
            if let q = inString {
                token.append(ch)
                if ch == q { flush(); inString = nil }
            } else if ch == "\"" || ch == "'" {
                flush(); inString = ch; token.append(ch)
            } else if ch.isLetter || ch.isNumber || ch == "_" || ch == "." && Double(token) != nil {
                token.append(ch)
            } else {
                flush()
                out = Text("\(out)\(Text(String(ch)).foregroundStyle(.white.opacity(0.6)))")
            }
        }
        flush()
        return out
    }
}

struct CodeCardView: View {
    var c: CodeCard

    var body: some View {
        let lines = c.code.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(icon: "chevron.left.forwardslash.chevron.right", title: "Kod", detail: c.lang.isEmpty ? "" : c.lang)
                ActionPill(title: "Nusxa", icon: "doc.on.doc", done: "Olindi") { copyToPasteboard(c.code) }
            }
            VStack(alignment: .leading, spacing: 0) {
                if !c.file.isEmpty {
                    HStack {
                        Text(c.file).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Text("\(lines.count) qator").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.04))
                }
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.prefix(60).enumerated()), id: \.offset) { i, l in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(i + 1)").foregroundStyle(.white.opacity(0.25)).frame(width: 22, alignment: .trailing)
                                Syntax.line(l)
                            }
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(10)
                }
                .frame(maxHeight: min(CGFloat(lines.count) * 17 + 22, 210))
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// translate

struct TranslateCardView: View {
    var c: TranslateCard

    private func chip(_ s: String, hot: Bool) -> some View {
        Text(s.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(hot ? .black.opacity(0.85) : .white.opacity(0.7))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(hot ? Palette.hot : Color.white.opacity(0.1)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                CardHeader(icon: "character.bubble.fill", title: "Tarjima")
                ActionPill(title: "Nusxa", icon: "doc.on.doc", done: "Olindi") { copyToPasteboard(c.text) }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    chip(c.from, hot: false)
                    Text(c.source).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
                }
                HStack(spacing: 6) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.hot)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }
                HStack(alignment: .top, spacing: 8) {
                    chip(c.to, hot: true)
                    Text(c.text).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        }
    }
}

// define

struct DefineCardView: View {
    var c: DefineCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "book.closed.fill", title: "Lugʻat", detail: c.source)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(c.word).font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(.white)
                if !c.phonetic.isEmpty { Text("/\(c.phonetic)/").font(.system(size: 12, design: .serif)).foregroundStyle(.white.opacity(0.5)) }
                if !c.pos.isEmpty {
                    Text(c.pos).font(.system(size: 10, weight: .bold)).italic().foregroundStyle(Palette.hot)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().stroke(Palette.hot.opacity(0.5)))
                }
            }
            .padding(.leading, 23)
            ForEach(Array(c.meanings.enumerated()), id: \.offset) { i, m in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Palette.hot).frame(width: 14)
                    Text(m).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 21)
            }
            if !c.example.isEmpty {
                Text("“\(c.example)”").font(.system(size: 12, design: .serif)).italic().foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 23).padding(.top, 2)
            }
        }
    }
}

// news

struct NewsCardView: View {
    var c: NewsCard
    @State private var hover: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(icon: "newspaper.fill", title: "Yangiliklar", detail: c.topic)
            ForEach(Array(c.items.enumerated()), id: \.offset) { i, n in
                HStack(alignment: .top, spacing: 10) {
                    LetterTile(name: n.source, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                        Text([n.source, relativeTime(n.time)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                    if !n.url.isEmpty {
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(hover == i ? 0.8 : 0.25))
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover == i ? 0.07 : 0)))
                .contentShape(Rectangle())
                .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
                .onTapGesture { if let u = URL(string: n.url) { NSWorkspace.shared.open(u) } }
            }
        }
    }
}

// link

struct LinkCardView: View {
    var c: LinkCard

    var body: some View {
        let host = URL(string: c.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? c.site
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "link", title: "Havola", detail: c.site.isEmpty ? host : c.site)
            HStack(alignment: .top, spacing: 11) {
                Text(String((c.site.isEmpty ? host : c.site).prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Palette.hot, Palette.banked], startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                    if !c.summary.isEmpty { Text(c.summary).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(3) }
                    Text(host).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Palette.hot.opacity(0.9)).lineLimit(1)
                }
            }
            .padding(.leading, 4)
            HStack(spacing: 6) {
                Spacer()
                ActionPill(title: "Nusxa", icon: "doc.on.doc", done: "Olindi") { copyToPasteboard(c.url) }
                ActionPill(title: "Ochish", icon: "safari") { if let u = URL(string: c.url) { NSWorkspace.shared.open(u) } }
            }
        }
    }
}

// deadlines

struct DeadlinesCardView: View {
    var c: DeadlinesCard

    private func left(_ d: Date, _ now: Date) -> (String, Color) {
        let s = d.timeIntervalSince(now)
        if s < 0 { return ("oʻtib ketdi", Palette.bad) }
        if s < 3600 { return ("\(Int(s / 60)) daq", Palette.bad) }
        if s < 86400 { return ("\(Int(s / 3600)) soat", Palette.bad) }
        let days = Int(s / 86400)
        return ("\(days) kun", days <= 3 ? Palette.amber : Palette.ok)
    }

    var body: some View {
        let df: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "uz_Latn_UZ"); f.dateFormat = "d MMM, HH:mm"; return f }()
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 7) {
                CardHeader(icon: "flag.checkered", title: "Muddatlar", detail: "\(c.items.count) ta")
                ForEach(Array(c.items.enumerated()), id: \.offset) { _, it in
                    let l = left(it.due, ctx.date)
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(l.1).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(it.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            Text([df.string(from: it.due), it.note].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(l.0).font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(l.1)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(l.1.opacity(0.15)))
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }
}

// timetable

struct TimetableCardView: View {
    var c: TimetableCard

    var body: some View {
        let tf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let now = ctx.date
            let next = c.lessons.first { $0.start > now }
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(icon: "graduationcap.fill", title: "Darslar", detail: c.day).padding(.bottom, 8)
                if c.lessons.isEmpty {
                    Text("Bugun dars yoʻq").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7)).padding(.leading, 23)
                }
                ForEach(c.lessons) { e in
                    let isNow = e.start <= now && now < e.end
                    let past = e.end <= now
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(tf.string(from: e.start)).font(.system(size: 12, weight: .bold).monospacedDigit())
                            Text(tf.string(from: e.end)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                        }
                        .foregroundStyle(.white).frame(width: 40, alignment: .trailing)
                        VStack(spacing: 0) {
                            Circle().fill(isNow ? Palette.hot : (past ? Color.white.opacity(0.25) : e.color)).frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Palette.hot.opacity(isNow ? 0.4 : 0), lineWidth: 4))
                            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1.5)
                        }
                        .frame(width: 12)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(e.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                if isNow { badge("hozir", Palette.hot) } else if e == next { badge("keyingi", Palette.amber) }
                            }
                            if !e.place.isEmpty { Text(e.place).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)) }
                            if isNow {
                                GeometryReader { g in
                                    let k = now.timeIntervalSince(e.start) / max(1, e.end.timeIntervalSince(e.start))
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.1))
                                        Capsule().fill(Palette.hot).frame(width: g.size.width * CGFloat(k))
                                    }
                                }
                                .frame(height: 3).padding(.top, 2)
                            }
                        }
                        .padding(.bottom, 10)
                        Spacer(minLength: 0)
                    }
                    .opacity(past ? 0.45 : 1)
                }
            }
        }
    }

    private func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 9.5, weight: .bold)).foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 1.5).background(Capsule().fill(c))
    }
}

// email

struct MailCardView: View {
    var c: MailCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CardHeader(icon: "envelope.fill", title: "Pochta", detail: c.account)
                if c.unread > 0 {
                    Text("\(c.unread) yangi").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2.5).background(Capsule().fill(Color(hex: 0x3D7BF2)))
                }
            }
            ForEach(Array(c.items.enumerated()), id: \.offset) { _, m in
                HStack(alignment: .top, spacing: 10) {
                    LetterTile(name: m.from, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(m.from).font(.system(size: 12, weight: m.unread ? .bold : .medium)).foregroundStyle(.white).lineLimit(1)
                            Spacer()
                            Text(relativeTime(m.time)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                        }
                        Text(m.subject).font(.system(size: 12, weight: m.unread ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(m.unread ? 0.95 : 0.65)).lineLimit(1)
                        if !m.snippet.isEmpty { Text(m.snippet).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1) }
                    }
                    if m.unread { Circle().fill(Color(hex: 0x3D7BF2)).frame(width: 7, height: 7).padding(.top, 4) }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

// clipboard

struct ClipCardView: View {
    var c: ClipCard

    var body: some View {
        let icon = ["url": "link", "code": "chevron.left.forwardslash.chevron.right", "image": "photo", "file": "doc"][c.kind] ?? "doc.on.clipboard"
        let kindName = ["url": "havola", "code": "kod", "image": "rasm", "file": "fayl"][c.kind] ?? "matn"
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                CardHeader(icon: "doc.on.clipboard.fill", title: "Bufer", detail: "\(kindName) · \(c.size)")
            }
            HStack(alignment: .top, spacing: 11) {
                if let img = c.image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: c.kind == "file" ? .fit : .fill)
                        .frame(width: c.kind == "file" ? 44 : 120, height: c.kind == "file" ? 44 : 80)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.hot)
                        .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
                }
                if c.kind == "code" {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(c.text.components(separatedBy: "\n").prefix(6).enumerated()), id: \.offset) { _, l in Syntax.line(l) }
                    }
                    .font(.system(size: 11, design: .monospaced)).lineLimit(1)
                } else if !c.text.isEmpty {
                    Text(c.text).font(.system(size: 12.5, design: c.kind == "url" ? .monospaced : .default))
                        .foregroundStyle(c.kind == "url" ? Palette.hot : .white.opacity(0.85)).lineLimit(5).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            HStack(spacing: 6) {
                Spacer()
                if c.kind == "url", let u = URL(string: c.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    ActionPill(title: "Ochish", icon: "safari") { NSWorkspace.shared.open(u) }
                }
                ActionPill(title: "Tozalash", icon: "trash", done: "Tozalandi") { NSPasteboard.general.clearContents() }
            }
        }
    }
}

// image

struct ImageCardView: View {
    var c: ImageCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(icon: "photo.fill", title: c.title, detail: (c.path as NSString).lastPathComponent)
            Image(nsImage: c.image).resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 190)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08)))
                .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: c.path)) ?? NSItemProvider() }
            HStack(spacing: 6) {
                Text("\(Int(c.image.size.width))×\(Int(c.image.size.height))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                Spacer()
                ActionPill(title: "Nusxa", icon: "doc.on.doc", done: "Olindi") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([c.image])
                }
                ActionPill(title: "Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c.path)]) }
                ActionPill(title: "Ochish", icon: "arrow.up.forward.app") { NSWorkspace.shared.open(URL(fileURLWithPath: c.path)) }
            }
        }
    }
}

// units

struct UnitCardView: View {
    var c: UnitCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(icon: "arrow.left.arrow.right", title: "Birliklar", detail: "\(c.from) → \(c.to)")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fmt(c.result)).font(.system(size: 30, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(c.to).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.leading, 23)
            Text("\(fmt(c.value)) \(c.from)").font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6)).padding(.leading, 23)
        }
    }

    private func fmt(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.decimalSeparator = "."
        f.maximumFractionDigits = abs(v) >= 100 ? 1 : 3
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

// Telegram draft

struct DraftCardView: View {
    var c: DraftCard
    @State private var text = ""

    var body: some View {
        let blue = Color(hex: 0x2AABEE)
        VStack(alignment: .leading, spacing: 9) {
            CardHeader(icon: "paperplane.fill", title: c.app, detail: c.to, tint: blue)
            HStack(alignment: .bottom, spacing: 8) {
                LetterTile(name: c.to, size: 30)
                TextField("Xabar", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(.white).lineLimit(1...5)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 4, bottomTrailingRadius: 16, topTrailingRadius: 16)
                        .fill(blue.opacity(0.28)))
            }
            HStack(spacing: 6) {
                Text("Yuborishdan oldin Telegram’da tekshirasiz").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                ActionPill(title: "Nusxa", icon: "doc.on.doc", done: "Olindi") { copyToPasteboard(text) }
                Button {
                    copyToPasteboard(text)
                    let handle = c.to.hasPrefix("@") ? String(c.to.dropFirst()) : ""
                    let url = handle.isEmpty
                        ? URL(string: "tg://msg?text=" + (text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))
                        : URL(string: "tg://resolve?domain=\(handle)")
                    if let url { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Telegram’da ochish", systemImage: "paperplane.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 5).background(Capsule().fill(blue))
                }
                .buttonStyle(PressDip())
            }
        }
        .onAppear { text = c.text }
    }
}
