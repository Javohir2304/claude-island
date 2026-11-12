import AppKit

/// The island's own brain: commands answered on this Mac, with no model and no network.
/// They work the same whether Claude is there or not; Claude is the upgrade for everything else.
enum LocalBrain {
    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for ch in ["ʻ", "ʼ", "‘", "’", "`", "´"] { t = t.replacingOccurrences(of: ch, with: "'") }
        t = t.replacingOccurrences(of: "\n", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        return spokenNumbers(t)
    }

    // MARK: spoken numbers (Whisper's Uzbek model writes numbers as words)

    private static let unitWords: [String: Int] = [
        "nol": 0, "bir": 1, "ikki": 2, "uch": 3, "to'rt": 4, "tort": 4, "besh": 5, "olti": 6, "yetti": 7,
        "sakkiz": 8, "to'qqiz": 9, "toqqiz": 9,
        "o'n": 10, "yigirma": 20, "o'ttiz": 30, "ottiz": 30, "qirq": 40, "ellik": 50,
        "oltmish": 60, "yetmish": 70, "sakson": 80, "to'qson": 90, "toqson": 90,
    ]
    private static let numberSuffixes = ["inchi", "nchi", "dan", "ga", "da", "ta", "ni", "lik"]
    private static let operatorWords: [String: String] = [
        "plyus": "+", "plus": "+", "qo'shuv": "+", "minus": "-", "ayiruv": "-", "karra": "*",
        "ko'paytir": "*", "ko'paytiruv": "*", "ko'paytirilsa": "*", "ko'paytirish": "*", "times": "*",
        "bo'lingan": "/", "bo'linsa": "/", "bo'lish": "/",
    ]

    /// A number word, possibly with a suffix ("beshga" -> (5, "ga")).
    private static func numberWord(_ w: String) -> (kind: String, value: Int, suffix: String)? {
        func classify(_ base: String) -> (String, Int)? {
            if let v = unitWords[base] { return ("n", v) }
            if base == "yuz" { return ("yuz", 100) }
            if base == "ming" { return ("ming", 1000) }
            return nil
        }
        if let c = classify(w) { return (c.0, c.1, "") }
        for suf in numberSuffixes where w.hasSuffix(suf) && w.count > suf.count + 1 {
            let base = String(w.dropLast(suf.count))
            if let c = classify(base) { return (c.0, c.1, suf) }
        }
        return nil
    }

    /// "o'n besh daqiqaga" -> "15 daqiqaga", "bir yarim soat" -> "1.5 soat", "o'n ikki karra uch" -> "12 * 3".
    /// Only runs that start with a clear number word are touched ("bir" alone stays a word).
    static func spokenNumbers(_ t: String) -> String {
        let words = t.split(separator: " ").map(String.init)
        var out: [String] = []
        var i = 0
        while i < words.count {
            if let op = operatorWords[words[i]] { out.append(op); i += 1; continue }
            guard numberWord(words[i]) != nil else { out.append(words[i]); i += 1; continue }
            var total = 0, current = 0, used = 0, suffix = ""
            var j = i
            while j < words.count, let n = numberWord(words[j]) {
                switch n.kind {
                case "yuz": current = max(current, 1) * 100
                case "ming": total += max(current, 1) * 1000; current = 0
                default: current += n.value
                }
                used += 1
                j += 1
                if !n.suffix.isEmpty { suffix = n.suffix; break }
            }
            var value = Double(total + current)
            if suffix.isEmpty, j < words.count, words[j] == "yarim" { value += 0.5; j += 1 }
            // "bir" on its own usually means "a/one" in a sentence: keep it unless a unit follows.
            let lone = used == 1 && (words[i] == "bir" || words[i] == "yuz" || words[i] == "ming") && suffix.isEmpty
                && !(j < words.count && durationOrUnitWord(words[j]))
            if lone {
                out.append(words[i]); i += 1; continue
            }
            let num = value == value.rounded() ? String(Int(value)) : String(value)
            out.append(num + suffix)
            i = j
        }
        return out.joined(separator: " ")
    }

    private static func durationOrUnitWord(_ w: String) -> Bool {
        ["soat", "daqiqa", "minut", "soniya", "sekund", "km", "kg", "metr", "foiz", "%"].contains { w.hasPrefix($0) }
    }

    /// Returned when the answer comes later through `later` (weather, calendar, system load).
    static let pending = "\u{1}pending"

    /// The last undoable change; "bekor qil", "oops" or the card's button runs it.
    static var undoAction: (() -> String)?

    static func performUndo(_ model: IslandModel) -> String {
        guard let u = undoAction else { return "Qaytaradigan narsa yoʻq." }
        undoAction = nil
        let r = u()
        if case .setting(var c) = model.card { c.undoable = false; c.detail = "qaytarildi"; model.card = .setting(c) }
        return r
    }

    static func handle(_ raw: String, model: IslandModel, claudeReady: Bool, config: OrolConfig,
                       later: @escaping (String, CardKind?) -> Void) -> String? {
        let t = normalize(raw)
        guard !t.isEmpty else { return nil }
        let words = t.split(separator: " ").count
        if ["bekor qil", "qaytar", "undo", "oops", "orqaga qaytar", "ups", "o'zgarishni qaytar"].contains(t) {
            return performUndo(model)
        }
        if let r = help(t, ready: claudeReady) { return r }
        if words <= 6, let r = listening(t, model: model) { return r }
        if words <= 6, let r = wifi(t, model: model) { return r }
        if words <= 8, let r = system(t, model: model, later: later) { return r }
        if words <= 9, let r = calendar(t, model: model, later: later) { return r }
        if words <= 9, let r = weather(t, model: model, config: config, later: later) { return r }
        if words <= 10, let r = directions(t, model: model, config: config, later: later) { return r }
        if words <= 8, let r = place(t, model: model, config: config, later: later) { return r }
        if words <= 8, let r = currency(t, model: model, later: later) { return r }
        if words <= 7, let r = widgets(t, raw: raw, model: model, claudeReady: claudeReady, later: later) { return r }
        if let r = timers(t, model: model) { return r }
        if words <= 5, let r = media(t, model: model) { return r }
        if words <= 6, let r = volume(t, model: model) { return r }
        if words <= 5, let r = appearance(t, model: model) { return r }
        if words <= 4, let r = lock(t) { return r }
        if words <= 6, let r = openApp(t) { return r }
        if let r = percent(t) { return r }
        if words <= 8, let r = convert(t) {
            if let u = lastUnits { model.card = .units(u); lastUnits = nil }
            return r
        }
        if let r = calculate(t) { return r }
        if words <= 7, let r = clock(t) { return r }
        if words <= 6, let r = battery(t, model: model) { return r }
        return nil
    }

    // MARK: help

    static func help(_ t: String, ready: Bool) -> String? {
        let asks = ["yordam", "help", "nima qila olasan", "nimalar qila olasan", "buyruqlar", "komandalar",
                    "what can you do", "nima qilasan"]
        guard asks.contains(t) else { return nil }
        let tail = ready
            ? " Qolgan hamma savolga Claude javob beradi."
            : " Boshqa savollar navbatga qoʻyiladi va Claude qaytganda javob beriladi."
        return "Claude’siz ham ishlaydigan buyruqlar: “5 daqiqaga taymer”, “10 daqiqadan keyin choy deb eslat”, "
            + "“taymer qancha qoldi”, “keyingi qoʻshiq”, “pauza”, “ovoz 30”, “ovozni oʻchir”, “Safari’ni och”, "
            + "“tungi rejim”, “ekranni qulfla”, “soat necha”, “bugun nechanchi”, “batareya”, “(12+8)*3”, "
            + "“80 ning 15 foizi”, “10 km necha mil”." + tail
    }

    // MARK: timers and reminders

    private static let durationPattern =
        #"(\d+(?:[.,]\d+)?)\s*(soniya\w*|sekund\w*|seconds?|secs?|daqiqa\w*|minut\w*|minutes?|mins?|soat\w*|hours?|hrs?|s|m|h)\b"#

    /// Total seconds and the text with the durations taken out.
    static func duration(in text: String) -> (TimeInterval, String)? {
        guard let re = try? NSRegularExpression(pattern: durationPattern, options: [.caseInsensitive]) else { return nil }
        var total: TimeInterval = 0
        var rest = text
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let all = Range(m.range, in: text), let r1 = Range(m.range(at: 1), in: text),
                  let r2 = Range(m.range(at: 2), in: text),
                  let n = Double(text[r1].replacingOccurrences(of: ",", with: ".")) else { continue }
            let unit = text[r2].lowercased()
            if unit.hasPrefix("soat") || unit.hasPrefix("h") { total += n * 3600 }
            else if unit.hasPrefix("d") || unit.hasPrefix("m") { total += n * 60 }
            else { total += n }
            if let rr = Range(NSRange(all, in: text), in: rest) { rest.replaceSubrange(rr, with: " ") }
        }
        if text.contains("yarim soat") { total += 1800; rest = rest.replacingOccurrences(of: "yarim soat", with: " ") }
        return total > 0 && total <= 24 * 3600 ? (total, rest) : nil
    }

    private static func reminderLabel(_ rest: String) -> String {
        let drop: Set<String> = ["eslat", "eslatib", "eslatgin", "eslatib qo'y", "qo'y", "menga", "deb", "keyin", "dan",
                                 "remind", "me", "in", "to", "about", "please", "iltimos", "ga", "taymer", "timer", "qo'ying"]
        var words = rest.split(separator: " ").map(String.init).filter { !drop.contains($0) && !$0.hasPrefix("esla") }
        if words.first == "that" { words.removeFirst() }
        let s = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "Eslatma" }
        let cut = s.count > 28 ? String(s.prefix(27)) + "…" : s
        return cut.prefix(1).uppercased() + cut.dropFirst()
    }

    static func timers(_ t: String, model: IslandModel) -> String? {
        let isTimer = t.contains("taymer") || t.contains("timer")
        let isRemind = t.contains("esla") || t.contains("remind")
        guard isTimer || isRemind else { return nil }
        if isTimer, ["bekor", "cancel", "o'chir", "stop", "to'xtat"].contains(where: t.contains) {
            guard !model.timers.isEmpty else { return "Hozir ishlab turgan taymer yoʻq." }
            model.timers.removeAll()
            return "Taymer bekor qilindi."
        }
        if ["qancha qoldi", "qoldi", "left", "remaining", "qanaqa taymer", "qaysi taymer"].contains(where: t.contains) {
            guard !model.timers.isEmpty else { return "Hozir ishlab turgan taymer yoʻq." }
            let list = model.timers.sorted { $0.end < $1.end }
                .map { "\($0.label): \(formatClock($0.end.timeIntervalSinceNow))" }
            model.card = .timers
            return "Qoldi — " + list.joined(separator: ", ") + "."
        }
        guard let (seconds, rest) = duration(in: t) else { return nil }
        let label = isRemind ? reminderLabel(rest) : "Taymer"
        model.timers.append(TimerItem(label: label, end: Date().addingTimeInterval(seconds), total: seconds))
        model.card = .timers
        if isRemind { return "\(humanDuration(seconds))dan keyin eslataman: \(label)." }
        return "Taymer qoʻyildi: \(humanDuration(seconds))."
    }

    // MARK: media

    static func media(_ t: String, model: IslandModel) -> String? {
        let next = ["keyingi qo'shiq", "keyingisi", "keyingi trek", "next song", "next track", "skip", "keyingi"]
        let prev = ["oldingi qo'shiq", "oldingisi", "oldingi trek", "previous song", "previous track", "oldingi"]
        let toggle = ["pauza", "pause", "musiqani to'xtat", "to'xtat", "davom ettir", "play", "resume",
                      "musiqani qo'y", "musiqa qo'y", "musiqani davom ettir"]
        if (next.contains(t) || prev.contains(t) || toggle.contains(t)), let m = model.media, !m.controllable, !AXMedia.trusted {
            model.onMedia("playpause")          // asks macOS for the permission
            return "\(m.appName)ni boshqarish uchun Orolga Accessibility ruxsati kerak: Tizim sozlamalari → Maxfiylik va xavfsizlik → Accessibility → Orol."
        }
        if next.contains(t) { model.onMedia("next"); return "Keyingi qoʻshiq." }
        if prev.contains(t) { model.onMedia("previous"); return "Oldingi qoʻshiq." }
        if toggle.contains(t) { model.onMedia("playpause"); return "Bajarildi." }
        let what = ["qaysi qo'shiq", "nima qo'shiq", "bu qaysi qo'shiq", "what's playing", "what song", "nima chalyapti"]
        if what.contains(where: t.contains) {
            guard let m = model.media else { return "Hozir hech narsa chalinmayapti." }
            model.card = .media
            return "\(m.title)" + (m.artist.isEmpty ? "" : " — \(m.artist)") + " (\(m.appName))."
        }
        return nil
    }

    // MARK: system: volume, appearance, lock, apps

    @discardableResult
    private static func script(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { olog("applescript failed: \(err)") }
        return err == nil ? r : nil
    }

    static func volume(_ t: String, model: IslandModel) -> String? {
        let about = t.contains("ovoz") || t.contains("volume") || t.contains("tovush") || t == "mute" || t == "unmute"
        guard about, !t.contains("ovozli"), !t.contains("chiqarib"), !t.contains("tanish") else { return nil }
        let current = Int(script("output volume of (get volume settings)")?.int32Value ?? 50)
        let wasMuted = script("output muted of (get volume settings)")?.booleanValue ?? false
        func changed(_ v: Int, muted: Bool, _ text: String) -> String {
            undoAction = {
                script("set volume output volume \(current)\nset volume output muted \(wasMuted)")
                return "Ovoz qaytarildi: \(current)%" + (wasMuted ? " (oʻchiq)." : ".")
            }
            model.card = .setting(SettingCard(icon: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", title: "Ovoz",
                                              detail: muted ? "oʻchirildi" : "\(v)%", level: muted ? 0 : Double(v) / 100,
                                              undoable: true))
            return text
        }
        if ["o'chir", "mute", "jim"].contains(where: t.contains) && !t.contains("unmute") {
            script("set volume output muted true")
            return changed(current, muted: true, "Ovoz oʻchirildi.")
        }
        if let m = t.range(of: #"\d{1,3}"#, options: .regularExpression), let n = Int(t[m]) {   // also "30ga"
            let v = max(0, min(100, n))
            script("set volume output muted false\nset volume output volume \(v)")
            return changed(v, muted: false, "Ovoz \(v)%.")
        }
        if ["necha", "qancha", "how loud", "what"].contains(where: t.contains) {
            let muted = script("output muted of (get volume settings)")?.booleanValue ?? false
            return muted ? "Ovoz oʻchirilgan (\(current)%)." : "Ovoz \(current)%."
        }
        if ["oshir", "ko'tar", "baland", "up", "louder", "kuchaytir"].contains(where: t.contains) {
            let v = min(100, current + 10)
            script("set volume output muted false\nset volume output volume \(v)")
            return changed(v, muted: false, "Ovoz \(v)%.")
        }
        if ["pasaytir", "kamaytir", "past", "down", "quieter", "sekin"].contains(where: t.contains) {
            let v = max(0, current - 10)
            script("set volume output volume \(v)")
            return changed(v, muted: false, "Ovoz \(v)%.")
        }
        if ["yoq", "unmute", "qaytar"].contains(where: t.contains) {
            script("set volume output muted false")
            return changed(current, muted: false, "Ovoz yoqildi (\(current)%).")
        }
        return nil
    }

    static func appearance(_ t: String, model: IslandModel) -> String? {
        let dark = ["tungi rejim", "qorong'i rejim", "dark mode", "tungi mavzu"]
        let light = ["kunduzgi rejim", "yorug' rejim", "light mode", "kunduzgi mavzu"]
        let want: Bool
        if dark.contains(where: t.contains) { want = true }
        else if light.contains(where: t.contains) { want = false }
        else { return nil }
        let wasDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        undoAction = {
            DispatchQueue.global(qos: .userInitiated).async {
                script("tell application \"System Events\" to tell appearance preferences to set dark mode to \(wasDark)")
            }
            return wasDark ? "Tungi rejim qaytarildi." : "Kunduzgi rejim qaytarildi."
        }
        model.card = .setting(SettingCard(icon: want ? "moon.fill" : "sun.max.fill", title: "Mavzu",
                                          detail: (wasDark ? "tungi" : "kunduzgi") + " → " + (want ? "tungi" : "kunduzgi"),
                                          level: nil, undoable: true))
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = script("tell application \"System Events\" to tell appearance preferences to set dark mode to \(want)") != nil
            if !ok {
                DispatchQueue.main.async {
                    model.showFlash(Flash(icon: "lock.fill", left: "Ruxsat kerak", right: "Privacy → Automation", tint: .orange), seconds: 6)
                }
            }
        }
        return want ? "Tungi rejim yoqildi." : "Kunduzgi rejim yoqildi."
    }

    static func lock(_ t: String) -> String? {
        let asks = ["ekranni qulfla", "qulfla", "lock screen", "lock the screen", "ekranni o'chir", "kompyuterni qulfla"]
        guard asks.contains(t) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
        return "Ekran oʻchirildi."
    }

    private static let aliases: [String: String] = [
        "sozlamalar": "System Settings", "settings": "System Settings", "kalkulyator": "Calculator",
        "kalendar": "Calendar", "taqvim": "Calendar", "eslatmalar": "Reminders", "qaydlar": "Notes",
        "musiqa": "Music", "xabarlar": "Messages", "pochta": "Mail", "rasmlar": "Photos", "suratlar": "Photos",
        "brauzer": "Safari", "xarita": "Maps", "fayllar": "Finder", "vscode": "Visual Studio Code",
        "vs code": "Visual Studio Code", "code": "Visual Studio Code", "claude": "Claude",
    ]

    private static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    private static var appIndex: [String: URL] = {
        var out: [String: URL] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", home + "/Applications"]
        for d in dirs {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? [] where name.hasSuffix(".app") {
                let k = key(String(name.dropLast(4)))
                if out[k] == nil { out[k] = URL(fileURLWithPath: d).appendingPathComponent(name) }
            }
        }
        if out["finder"] == nil { out["finder"] = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app") }
        return out
    }()

    static func findApp(_ name: String) -> URL? {
        var candidates = [name]
        for suf in ["'ni", "ni", "'ga", "ga"] where name.hasSuffix(suf) && name.count > suf.count + 2 {
            candidates.append(String(name.dropLast(suf.count)))
        }
        for c in candidates {
            let k = key(aliases[c] ?? c)
            guard !k.isEmpty else { continue }
            if let u = appIndex[k] { return u }
            if k.count >= 3 {
                let hits = appIndex.filter { $0.key.hasPrefix(k) }.sorted { $0.key.count < $1.key.count }
                if let u = hits.first?.value { return u }
            }
        }
        return nil
    }

    static func openApp(_ t: String) -> String? {
        let patterns = [#"^(?:open|launch|start)\s+(.+)$"#,
                        #"^(.+?)\s+(?:ni\s+)?(?:och|ochib ber|ochgin|ochib qo'y|ishga tushir)$"#]
        var name: String?
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let r = Range(m.range(at: 1), in: t) else { continue }
            name = String(t[r]).trimmingCharacters(in: .whitespaces)
            break
        }
        guard let name, !name.isEmpty, let url = findApp(name) else { return nil }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return "\(url.deletingPathExtension().lastPathComponent) ochildi."
    }

    // MARK: numbers

    private static func formatNumber(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "uz_Latn_UZ")
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(v) < 1 ? 6 : 3
        f.usesSignificantDigits = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    private static func number(_ s: Substring) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }

    static func percent(_ t: String) -> String? {
        let pats = [(#"(\d+(?:[.,]\d+)?)\s*(?:ning|dan)\s*(\d+(?:[.,]\d+)?)\s*(?:%|foiz)"#, false),
                    (#"(\d+(?:[.,]\d+)?)\s*(?:%|percent|foizi?)\s*(?:of|from)\s*(\d+(?:[.,]\d+)?)"#, true)]
        for (p, swapped) in pats {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let r1 = Range(m.range(at: 1), in: t), let r2 = Range(m.range(at: 2), in: t),
                  let a = number(t[r1]), let b = number(t[r2]) else { continue }
            let (base, pct) = swapped ? (b, a) : (a, b)
            return "\(formatNumber(base)) ning \(formatNumber(pct))% i = \(formatNumber(base * pct / 100))."
        }
        return nil
    }

    private enum Dim { case length, mass, volume, speed, temp }
    private static let units: [String: (Dim, Double, String)] = [
        "km": (.length, 1000, "km"), "kilometr": (.length, 1000, "km"), "m": (.length, 1, "m"), "metr": (.length, 1, "m"),
        "sm": (.length, 0.01, "sm"), "cm": (.length, 0.01, "sm"), "mm": (.length, 0.001, "mm"),
        "mil": (.length, 1609.344, "mil"), "mile": (.length, 1609.344, "mil"), "miles": (.length, 1609.344, "mil"),
        "milya": (.length, 1609.344, "mil"), "ft": (.length, 0.3048, "fut"), "fut": (.length, 0.3048, "fut"),
        "foot": (.length, 0.3048, "fut"), "feet": (.length, 0.3048, "fut"), "dyuym": (.length, 0.0254, "dyuym"),
        "inch": (.length, 0.0254, "dyuym"), "inches": (.length, 0.0254, "dyuym"), "yard": (.length, 0.9144, "yard"),
        "kg": (.mass, 1, "kg"), "kilogramm": (.mass, 1, "kg"), "g": (.mass, 0.001, "g"), "gramm": (.mass, 0.001, "g"),
        "gram": (.mass, 0.001, "g"), "tonna": (.mass, 1000, "t"), "lb": (.mass, 0.45359237, "funt"),
        "lbs": (.mass, 0.45359237, "funt"), "funt": (.mass, 0.45359237, "funt"), "pound": (.mass, 0.45359237, "funt"),
        "pounds": (.mass, 0.45359237, "funt"), "oz": (.mass, 0.028349523, "unsiya"), "unsiya": (.mass, 0.028349523, "unsiya"),
        "l": (.volume, 1, "l"), "litr": (.volume, 1, "l"), "liter": (.volume, 1, "l"), "ml": (.volume, 0.001, "ml"),
        "gallon": (.volume, 3.785411784, "gallon"), "km/h": (.speed, 1, "km/soat"), "km/soat": (.speed, 1, "km/soat"),
        "mph": (.speed, 1.609344, "mph"), "c": (.temp, 0, "°C"), "°c": (.temp, 0, "°C"), "selsiy": (.temp, 0, "°C"),
        "celsius": (.temp, 0, "°C"), "f": (.temp, 1, "°F"), "°f": (.temp, 1, "°F"), "farengeyt": (.temp, 1, "°F"),
        "fahrenheit": (.temp, 1, "°F"), "kelvin": (.temp, 2, "K"),
    ]

    private static func unit(_ tok: String) -> (Dim, Double, String)? {
        if let u = units[tok] { return u }
        for suf in ["ga", "da", "dan", "ni", "ning", "lik", "ka"] where tok.hasSuffix(suf) && tok.count > suf.count {
            if let u = units[String(tok.dropLast(suf.count))] { return u }
        }
        return nil
    }

    static func convert(_ t: String) -> String? {
        var toks = t.split(separator: " ").map(String.init)
        // "10km" -> "10", "km"
        if let i = toks.firstIndex(where: { $0.range(of: #"^-?\d+(?:[.,]\d+)?[a-z°/]+$"#, options: .regularExpression) != nil }),
           let r = toks[i].range(of: #"^-?\d+(?:[.,]\d+)?"#, options: .regularExpression) {
            let num = String(toks[i][r]), rest = String(toks[i][r.upperBound...])
            toks.replaceSubrange(i...i, with: [num, rest])
        }
        guard let i = toks.firstIndex(where: { number(Substring($0)) != nil }), i + 1 < toks.count,
              let value = number(Substring(toks[i])), let a = unit(toks[i + 1]) else { return nil }
        guard let b = toks[(i + 2)...].compactMap({ unit($0) }).first(where: { $0.0 == a.0 && $0.2 != a.2 }) else { return nil }
        let out: Double
        if a.0 == .temp {
            let c: Double = a.1 == 0 ? value : (a.1 == 1 ? (value - 32) * 5 / 9 : value - 273.15)
            out = b.1 == 0 ? c : (b.1 == 1 ? c * 9 / 5 + 32 : c + 273.15)
        } else {
            out = value * a.1 / b.1
        }
        lastUnits = UnitCard(value: value, from: a.2, result: out, to: b.2)
        return "\(formatNumber(value)) \(a.2) = \(formatNumber(out)) \(b.2)."
    }

    /// Plain arithmetic: + − × ÷ ^ % and brackets, by a small parser (never evaluates code).
    static func calculate(_ t: String) -> String? {
        var s = " " + t + " "
        let fillers = ["hisoblab ber", "hisobla", "necha bo'ladi", "nechchi bo'ladi", "nechi bo'ladi", "qancha bo'ladi",
                       "nechchi", "nechi", "necha", "qancha", "bo'ladi", "teng", "what is", "what's", "calculate",
                       "equals", "="]
        for f in fillers { s = s.replacingOccurrences(of: f, with: " ") }
        s = s.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "x", with: "*").replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.range(of: #"^[0-9.+\-*/^()% ]+$"#, options: .regularExpression) != nil,
              s.range(of: #"[\d)%]\s*[-+*/^]\s*[\d(.]"#, options: .regularExpression) != nil else { return nil }
        var p = Calc(chars: Array(s))
        guard let v = p.parse() else { return nil }
        guard v.isFinite else { return "Nolga boʻlib boʻlmaydi." }
        return "\(t.trimmingCharacters(in: .whitespaces)) = \(formatNumber(v))"
    }

    private struct Calc {
        var chars: [Character]
        var i = 0
        var depth = 0

        mutating func parse() -> Double? {
            guard let v = expr() else { return nil }
            skip()
            return i == chars.count ? v : nil
        }
        mutating func skip() { while i < chars.count, chars[i] == " " { i += 1 } }
        mutating func peek() -> Character? { skip(); return i < chars.count ? chars[i] : nil }
        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                i += 1
                guard let r = power() else { return nil }
                v = c == "*" ? v * r : v / r
            }
            return v
        }
        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = power() else { return nil }
                return pow(b, e)
            }
            return b
        }
        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            guard var v = primary() else { return nil }
            while peek() == "%" { i += 1; v /= 100 }
            return v
        }
        mutating func primary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                depth += 1
                guard depth < 40 else { return nil }
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                depth -= 1
                return v
            }
            var s = ""
            while i < chars.count, chars[i].isNumber || chars[i] == "." { s.append(chars[i]); i += 1 }
            return Double(s)
        }
    }

    // MARK: clock and battery

    static func clock(_ t: String) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uz_Latn_UZ")
        let timeAsks = [#"^(hozir )?soat (necha|nechchi|nechi)"#, #"^vaqt (necha|qancha)"#, #"what time"#,
                        #"^what's the time"#, #"^hozir soat"#, #"^time$"#]
        if timeAsks.contains(where: { t.range(of: $0, options: .regularExpression) != nil }) {
            f.dateFormat = "HH:mm"
            return "Soat \(f.string(from: Date()))."
        }
        let dateAsks = [#"^bugun (necha|nechanchi|nechinchi|qaysi|nima kun)"#, #"^(bugungi )?sana"#,
                        #"today's date"#, #"what day is"#, #"what's the date"#, #"hafta(ning)? qaysi kuni"#]
        if dateAsks.contains(where: { t.range(of: $0, options: .regularExpression) != nil }) {
            f.dateFormat = "d-MMMM, EEEE"
            return "Bugun \(f.string(from: Date()))."
        }
        return nil
    }

    // MARK: pause "Hey Claude"

    /// 900 -> "15 daqiqa", 5400 -> "1 soat 30 daqiqa", 45 -> "45 soniya"
    static func humanDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        var parts: [String] = []
        if s >= 3600 { parts.append("\(s / 3600) soat") }
        if (s % 3600) / 60 > 0 { parts.append("\((s % 3600) / 60) daqiqa") }
        if s % 60 > 0 && s < 600 { parts.append("\(s % 60) soniya") }
        return parts.isEmpty ? "0 soniya" : parts.joined(separator: " ")
    }

    static func listening(_ t: String, model: IslandModel) -> String? {
        let resume = ["tinglashni davom ettir", "tinglashni yoq", "qayta tingla", "start listening", "resume listening"]
        if resume.contains(where: t.contains) {
            model.onPauseListening(nil)
            return "“Hey Claude” yana tinglanmoqda."
        }
        let pause = ["tinglama", "tinglashni to'xtat", "tinglashni o'chir", "stop listening", "pause listening", "eshitma"]
        guard pause.contains(where: t.contains) else { return nil }
        let seconds = duration(in: t)?.0 ?? 3600
        model.onPauseListening(seconds)
        return "“Hey Claude” \(humanDuration(seconds))ga toʻxtatildi. Hotkey ishlayveradi."
    }

    // MARK: Wi-Fi, system, calendar, weather

    static func wifi(_ t: String, model: IslandModel) -> String? {
        guard ["wifi", "wi-fi", "vay fay", "vayfay", "wi fi"].contains(where: t.contains) else { return nil }
        let off = ["o'chir", "off", "uzib", "uz"].contains(where: { t.contains($0) })
        let on = ["yoq", " on", "ulab", "ula"].contains(where: { t.contains($0) }) || t.hasSuffix("on")
        guard let was = LocalData.wifiOn() else { return "Wi-Fi topilmadi." }
        let state = { (b: Bool) in b ? "yoniq" : "oʻchiq" }
        if !off && !on {
            model.card = .setting(SettingCard(icon: was ? "wifi" : "wifi.slash", title: "Wi-Fi", detail: state(was), level: nil, undoable: false))
            return "Wi-Fi \(state(was))."
        }
        let want = on && !off
        guard want != was else { return "Wi-Fi allaqachon \(state(was))." }
        guard LocalData.setWifi(want) else { return "Wi-Fi’ni oʻzgartirib boʻlmadi." }
        undoAction = { LocalData.setWifi(was) ? "Wi-Fi qaytarildi: \(state(was))." : "Wi-Fi’ni qaytarib boʻlmadi." }
        model.card = .setting(SettingCard(icon: want ? "wifi" : "wifi.slash", title: "Wi-Fi",
                                          detail: "\(state(was)) → \(state(want))", level: nil, undoable: true))
        return want ? "Wi-Fi yoqildi." : "Wi-Fi oʻchirildi. Claude internet qaytguncha navbat bilan ishlaydi."
    }

    static func system(_ t: String, model: IslandModel, later: @escaping (String, CardKind?) -> Void) -> String? {
        let asks = ["tizim holati", "kompyuter holati", "mac holati", "system status", "protsessor", "cpu", "ram",
                    "xotira qancha", "operativ xotira", "disk qancha", "diskda qancha", "kompyuter qanday", "tizim qanday"]
        let words = Set(t.split(separator: " ").map(String.init))
        // short ones ("ram", "cpu") must be whole words: "boraman" is not about memory
        guard asks.contains(where: { $0.count <= 4 ? words.contains($0) : t.contains($0) }) || t == "tizim" || t == "system" else { return nil }
        LocalData.system { s in
            let gb = 1_073_741_824.0
            later(String(format: "Protsessor %d%%, xotira %.1f / %.0f GB, diskda %.0f GB boʻsh.",
                         Int((s.cpu * 100).rounded()), s.ramUsed / gb, s.ramTotal / gb, s.diskFree / 1e9), .system(s))
        }
        return pending
    }

    static func calendar(_ t: String, model: IslandModel, later: @escaping (String, CardKind?) -> Void) -> String? {
        let asks = ["kalendar", "taqvim", "rejalarim", "uchrashuv", "calendar", "nima rejam", "nima ishlarim",
                    "tadbirlar", "meetings", "agenda"]
        guard asks.contains(where: t.contains) else { return nil }
        let offset = t.contains("ertaga") || t.contains("tomorrow") ? 1 : 0
        let title = offset == 1 ? "Ertaga" : "Bugun"
        LocalData.events(dayOffset: offset) { list in
            guard let list else {
                later("Kalendarga ruxsat yoʻq. System Settings → Privacy & Security → Calendars’da Orol’ga ruxsat bering.", nil)
                return
            }
            let card = CardKind.calendar(title: title, events: list)
            if list.isEmpty { later("\(title) kalendarda hech narsa yoʻq.", card); return }
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let first = list.first { !$0.allDay && $0.end > Date() } ?? list[0]
            later("\(title) \(list.count) ta tadbir. " + (first.allDay ? "\(first.title)." : "Eng yaqini: \(f.string(from: first.start)) da \(first.title)."), card)
        }
        return pending
    }

    static func weather(_ t: String, model: IslandModel, config: OrolConfig, later: @escaping (String, CardKind?) -> Void) -> String? {
        guard ["ob-havo", "obhavo", "ob havo", "havo qanday", "weather", "yomg'ir yog'adimi", "qor yog'adimi",
               "necha gradus", "harorat", "temperatura"].contains(where: t.contains) else { return nil }
        let skip: Set<String> = ["hozirda", "bugunda", "kunda", "haftada", "ertada"]
        let place = t.split(separator: " ").map(String.init).first {
            $0.hasSuffix("da") && $0.count > 4 && !skip.contains($0)
        }.map { String($0.dropLast(2)) }
        let tomorrow = t.contains("ertaga") || t.contains("tomorrow")
        LocalData.weather(place: place, home: (config.weatherCity, config.weatherLat, config.weatherLon)) { w in
            guard let w else {
                later(model.online ? "Ob-havo maʼlumotini olib boʻlmadi." : "Internet yoʻq, ob-havoni olib boʻlmadi.", nil)
                return
            }
            let card = CardKind.weather(w)
            if tomorrow, w.days.count > 1 {
                let d = w.days[1]
                later("Ertaga \(w.place)da \(Int(d.min.rounded()))…\(Int(d.max.rounded()))°, \(LocalData.weatherText(d.code).0)"
                      + (d.rain >= 30 ? ", yomgʻir ehtimoli \(d.rain)%." : "."), card)
            } else {
                var s = "\(w.place)da hozir \(Int(w.temp.rounded()))°, \(LocalData.weatherText(w.code).0)."
                if let rainy = w.hours.first(where: { $0.rain >= 50 }) {
                    let f = DateFormatter(); f.dateFormat = "HH:mm"
                    s += " Soat \(f.string(from: rainy.time)) atrofida yomgʻir ehtimoli \(rainy.rain)%."
                }
                later(s, card)
            }
        }
        return pending
    }

    // MARK: maps

    private static func match(_ t: String, _ patterns: [String]) -> String? {
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let r = Range(m.range(at: 1), in: t) else { continue }
            let s = t[r].trimmingCharacters(in: .whitespaces)
            if s.count >= 2 { return s }
        }
        return nil
    }

    /// Strips the Uzbek case ending from a place name ("chorsuga" -> "chorsu").
    private static func placeName(_ s: String) -> String {
        var w = s
        for suf in ["gacha", "ga", "ka", "qa", "ni", "da"] where w.hasSuffix(suf) && w.count > suf.count + 2 {
            w = String(w.dropLast(suf.count)); break
        }
        return w.trimmingCharacters(in: .whitespaces)
    }

    static func directions(_ t: String, model: IslandModel, config: OrolConfig, later: @escaping (String, CardKind?) -> Void) -> String? {
        let verbs = "(?:qanday|qancha vaqtda|necha daqiqada|qanaqa)?\\s*(?:boraman|borsam|boramiz|borish mumkin|yetaman|yetib boraman|yo'l|yo'li|yo'lni ko'rsat|marshrut)"
        let raw = match(t, [
            "^(?:menga )?(?:yandexda |yandex(?: xarita(?:lar)?)?da )?(.+?)(?:ga|gacha|ka|qa)\\s+(?:piyoda |mashinada |taksida |velosipedda |avtobusda |metroda |jamoat transportida )?" + verbs,
            "^(?:yandexda |yandex xaritada )(.+?)(?:ga|gacha)?(?: yo'l| marshrut)?$",
            "^(?:yo'l|marshrut|yo'nalish)\\s+(.+?)(?:ga|gacha)?$",
            "^(?:directions|route|navigate) to (.+)$", "^how (?:do i|to|can i) get to (.+)$",
        ])
        guard var dest = raw else { return nil }
        dest = placeName(dest)
        let mode: RouteCard.Mode = t.contains("avtobus") || t.contains("metro") || t.contains("jamoat transport") || t.contains("bus") ? .transit
            : t.contains("piyoda") || t.contains("walk") ? .walking
            : t.contains("velosiped") || t.contains("bike") ? .cycling : .driving
        Maps.route(to: dest, mode: mode, config: config) { r in
            switch r {
            case .success(let card):
                let tf = DateFormatter(); tf.dateFormat = "HH:mm"
                if t.contains("yandex") || card.mode == .transit, let u = card.yandexURL { NSWorkspace.shared.open(u) }
                if card.mode == .transit {
                    later("\(card.dest) \(distanceText(card.meters)) uzoqda. Avtobus va metro yoʻlini Yandex Xaritalarda ochdim.", .route(card))
                    return
                }
                later("\(card.dest): \(durationText(card.seconds)), \(distanceText(card.meters)). \(tf.string(from: card.arrive)) da yetib borasiz.", .route(card))
            case .failure(let e):
                later(e.text, nil)
            }
        }
        return pending
    }

    static func place(_ t: String, model: IslandModel, config: OrolConfig, later: @escaping (String, CardKind?) -> Void) -> String? {
        guard let raw = match(t, [
            "^(.+?) (?:qayerda joylashgan|qaerda joylashgan|xaritada qayerda|manzili qayerda|manzili)$",
            "^(.+?)(?:ni|ni xaritada) (?:xaritada )?ko'rsat$", "^xaritada (.+?)(?:ni)?(?: ko'rsat)?$",
            "^where is (.+)$", "^show (.+) on the map$",
        ]) else { return nil }
        let name = placeName(raw)
        Maps.place(name, config: config) { r in
            switch r {
            case .success(let p):
                let d = p.distance.map { ", sizdan \(distanceText($0))" } ?? ""
                later("\(p.name): \(p.address.isEmpty ? "manzil nomaʼlum" : p.address)\(d).", .place(p))
            case .failure(let e): later(e.text, nil)
            }
        }
        return pending
    }

    static var lastUnits: UnitCard?

    // MARK: the other widgets (clipboard, screenshot, news, deadlines, timetable, mail, dictionary, Telegram draft)

    static func widgets(_ t: String, raw: String, model: IslandModel, claudeReady: Bool,
                        later: @escaping (String, CardKind?) -> Void) -> String? {
        func has(_ list: [String]) -> Bool { list.contains(where: t.contains) }

        if has(["buferda", "buferdagi", "clipboard", "nusxada nima", "nusxalangan"]) {
            guard let c = LocalWidgets.clipboard() else { return "Bufer boʻsh." }
            model.card = .clip(c)
            let kind = ["url": "havola", "code": "kod", "image": "rasm", "file": "fayl"][c.kind] ?? "matn"
            return "Buferda \(kind) bor (\(c.size))."
        }
        if has(["skrinshot", "screenshot", "ekranni rasmga", "ekran rasmi"]) {
            LocalWidgets.screenshot { card in
                if let card { later("Skrinshot olindi: Rasmlar → Orol papkasida.", .image(card)) }
                else { later("Skrinshot olinmadi. Orol’ga Screen Recording ruxsati kerak: System Settings → Privacy & Security.", nil) }
            }
            return pending
        }
        if has(["yangiliklar", "yangilik", "news", "nima gaplar", "xabarlar nima"]) && !has(["telegram", "pochta", "email"]) {
            LocalWidgets.news { card in
                if let card { later("Soʻnggi yangiliklar: " + (card.items.first?.title ?? "") + ".", .news(card)) }
                else { later(model.online ? "Yangiliklarni olib boʻlmadi." : "Internet yoʻq, yangiliklarni olib boʻlmadi.", nil) }
            }
            return pending
        }
        if has(["muddat", "deadline", "dedlayn", "topshirishim kerak", "nima topshir"]) {
            LocalWidgets.deadlines { card, note in
                if let card {
                    let first = card.items[0]
                    let tf = DateFormatter(); tf.locale = Locale(identifier: "uz_Latn_UZ"); tf.dateFormat = "d-MMMM HH:mm"
                    later("\(card.items.count) ta muddat. Eng yaqini: \(first.title), \(tf.string(from: first.due)).", .deadlines(card))
                } else { later(note ?? "Yaqin muddatlar topilmadi.", nil) }
            }
            return pending
        }
        if has(["darslarim", "dars jadval", "darslar", "keyingi dars", "qaysi dars", "darsim"]) {
            let tomorrow = t.contains("ertaga")
            let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(tomorrow ? 86400 : 0)
            _ = day
            LocalData.events(dayOffset: tomorrow ? 1 : 0) { events in
                guard let events else { later("Kalendarga ruxsat yoʻq. System Settings → Privacy & Security → Calendars’da Orol’ga ruxsat bering.", nil); return }
                let lessons = events.filter { !$0.allDay }
                let card = TimetableCard(day: tomorrow ? "Ertaga" : "Bugun", lessons: lessons)
                if let next = lessons.first(where: { $0.start > Date() }) {
                    let tf = DateFormatter(); tf.dateFormat = "HH:mm"
                    later("Keyingi dars: \(next.title), \(tf.string(from: next.start)) da.", .timetable(card))
                } else {
                    later(lessons.isEmpty ? "\(card.day) dars yoʻq." : "\(card.day) \(lessons.count) ta dars.", .timetable(card))
                }
            }
            return pending
        }
        if has(["pochtam", "pochta", "emaillarim", "email", "xatlarim", "yangi xat"]) {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first != nil else { return nil }   // Claude (Gmail) answers
            LocalWidgets.mail { card in
                if let card { later(card.unread > 0 ? "\(card.unread) ta oʻqilmagan xat." : "Yangi xat yoʻq.", .mail(card)) }
                else { later("Mail’dan oʻqib boʻlmadi. Orol’ga Mail’ni boshqarishga ruxsat bering.", nil) }
            }
            return pending
        }
        // dictionary: "serendipity ma'nosi", "define serendipity", "X nima degani"
        let defPatterns = [#"^define (\S+)$"#, #"^(\S+) (?:so'zining |sozining )?ma'nosi(?: nima)?$"#, #"^(\S+) nima degani$"#, #"^what does (\S+) mean$"#]
        for p in defPatterns {
            if let m = t.range(of: p, options: .regularExpression) {
                let word = t[m].replacingOccurrences(of: p, with: "$1", options: .regularExpression)
                if let d = LocalWidgets.define(word) {
                    model.card = .define(d)
                    return d.meanings.first.map { "\(word): \($0)" } ?? word
                }
                return nil                                     // not in the Mac's dictionary: Claude explains
            }
        }
        // Telegram draft: "azizga telegramda ertaga uchrashamiz deb yoz"
        if t.contains("telegram"), let r = t.range(of: #"^(.+?)(?:ga|ka|qa)? telegramda (.+?) deb (?:yoz|yubor|jo'nat)$"#, options: .regularExpression) {
            let s = String(t[r])
            let to = s.replacingOccurrences(of: #"^(.+?)(?:ga|ka|qa)? telegramda (.+?) deb (?:yoz|yubor|jo'nat)$"#, with: "$1", options: .regularExpression)
            let text = s.replacingOccurrences(of: #"^(.+?)(?:ga|ka|qa)? telegramda (.+?) deb (?:yoz|yubor|jo'nat)$"#, with: "$2", options: .regularExpression)
            let name = to.prefix(1).uppercased() + to.dropFirst()
            model.card = .draft(DraftCard(app: "Telegram", to: name, text: text.prefix(1).uppercased() + text.dropFirst()))
            return "Xabar tayyor. Tekshirib, Telegram’da yuboring."
        }
        if t.contains("telegram") && has(["chatlar", "xabarlarim", "kim yozdi", "o'qilmagan"]) {
            return "Telegram chatlarini oʻqish uchun Telegram hisobingizga API orqali kirish kerak (my.telegram.org’dagi api_id va telefon raqam bilan). Hozircha Orol faqat xabar qoralamasini tayyorlay oladi: “Azizga telegramda … deb yoz”."
        }
        return nil
    }

    // MARK: currency

    static func currency(_ t: String, model: IslandModel, later: @escaping (String, CardKind?) -> Void) -> String? {
        let words = t.replacingOccurrences(of: "?", with: "").split(separator: " ").map(String.init)
        var amount: Double?
        var codes: [String] = []
        for w in words {
            if let v = Double(w.replacingOccurrences(of: ",", with: ".")) { if amount == nil { amount = v }; continue }
            if let c = Money.code(w), codes.last != c { codes.append(c) }
        }
        let rateQuestion = t.contains("kurs") || t.contains("rate")
        guard let from = codes.first, amount != nil || rateQuestion || codes.count >= 2 else { return nil }
        guard codes.count >= 2 || rateQuestion || t.contains("necha") || t.contains("qancha") || t.contains("how much") else { return nil }
        let to = codes.count >= 2 ? codes[1] : (from == "UZS" ? "USD" : "UZS")
        let a = amount ?? 1
        Money.rates { rates, updated in
            guard let rates, let rf = from == "USD" ? 1 : rates[from], let rt = to == "USD" ? 1 : rates[to], rf > 0 else {
                later("Valyuta kursini olib boʻlmadi" + (model.online ? "." : ": internet yoʻq va saqlangan kurs ham yoʻq."), nil)
                return
            }
            let rate = rt / rf
            let card = CurrencyCard(amount: a, from: from, to: to, result: a * rate, rate: rate, updated: updated ?? Date())
            later("\(Money.format(a, from)) \(from) = \(Money.format(a * rate, to)) \(to).", .currency(card))
        }
        return pending
    }

    static func battery(_ t: String, model: IslandModel) -> String? {
        guard t.contains("batareya") || t.contains("zaryad") || t.contains("battery") else { return nil }
        let isQuestion = t.split(separator: " ").count <= 3
            || ["necha", "qancha", "foiz", "level", "how much", "qanday holat"].contains(where: t.contains)
        guard isQuestion else { return nil }
        let b = model.battery
        guard b.present else { return "Bu Mac’da batareya yoʻq." }
        let state = b.charging ? "quvvatlanmoqda" : (b.plugged ? "quvvatlagichga ulangan" : "batareyadan ishlayapti")
        return "Batareya \(b.percent)%, \(state)."
    }
}
