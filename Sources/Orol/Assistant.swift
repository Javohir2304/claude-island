import AppKit
import Network
import SwiftUI

/// One long-lived `claude -p --input-format stream-json` process: messages in, events out.
final class ClaudeProcess {
    private let executable: String
    private let args: [String]
    private let env: [String: String]
    private let cwd: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private let lock = NSLock()
    /// Both called on the main queue.
    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?

    /// false for one-shot runs (`claude -p "<task>"`): they get no stdin at all.
    private let interactive: Bool

    init(executable: String, args: [String], env: [String: String], cwd: URL, interactive: Bool = true) {
        self.executable = executable
        self.args = args
        self.env = env
        self.cwd = cwd
        self.interactive = interactive
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        guard !isRunning else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = cwd
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = interactive ? inPipe : FileHandle.nullDevice
        p.standardOutput = outPipe
        p.standardError = errPipe
        buffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.consume(d)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                olog("[claude stderr] " + s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            }
        }
        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.process = nil
                self.stdin = nil
                self.onExit?(proc.terminationStatus)
            }
        }
        do {
            try p.run()
            process = p
            stdin = interactive ? inPipe.fileHandleForWriting : nil
        } catch {
            olog("claude start failed: \(error)")
            DispatchQueue.main.async { self.onExit?(-1) }
        }
    }

    private func consume(_ d: Data) {
        lock.lock()
        buffer.append(d)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(Data(buffer[buffer.startIndex..<nl]))
            buffer = Data(buffer[buffer.index(after: nl)...])
        }
        lock.unlock()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            DispatchQueue.main.async { [weak self] in self?.onEvent?(obj) }
        }
    }

    private func writeLine(_ obj: [String: Any]) {
        guard let h = stdin, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        do { try h.write(contentsOf: data) } catch { olog("claude stdin write failed: \(error)") }
    }

    func send(_ text: String) {
        if !isRunning { start() }
        writeLine(["type": "user", "message": ["role": "user", "content": text]])
    }

    func interrupt() {
        writeLine(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    func stop() {
        let p = process
        process = nil
        try? stdin?.close()
        stdin = nil
        if let p, p.isRunning { p.terminate() }
    }
}

/// The three tiers, after hey-claude: quick answers from a warm tool-less process,
/// lookups from a warm agent with tools and connectors, and real work as a headless
/// Claude Code task in a project folder. All of it is optional: when Claude is offline,
/// out of limit or signed out, the island's own commands still answer and anything else
/// waits in a queue until Claude is back.
final class Assistant {
    private let model: IslandModel
    private let hub: SessionHub
    private let speaker: Speaker
    private var config: OrolConfig
    private var quick: ClaudeProcess?
    private var agent: ClaudeProcess?
    private var tasks: [ClaudeProcess] = []

    private enum Tier { case quick, agent }
    private var active: Tier?
    private var generation = 0
    private var buffer = ""
    private var currentQuestion = ""
    private var byVoice = false
    private var history: [(q: String, a: String)] = []
    private var watchdog: DispatchWorkItem?
    private(set) var doneAt = Date.distantPast

    // Availability
    private enum Block { case none, limit, login, unreachable }
    private var block: Block = .none
    private var blockedUntil = Date.distantPast
    private var limitResetKnown = false
    private var lastReset: Date?
    private let pathMonitor = NWPathMonitor()
    private var stateTimer: Timer?
    var forceOffline = false { didSet { refreshState() } }

    /// The queued question being answered in the background (nothing shows until it's done).
    private var background: UUID?
    private var ui: Bool { background == nil }

    init(model: IslandModel, hub: SessionHub, speaker: Speaker, config: OrolConfig) {
        self.model = model
        self.hub = hub
        self.speaker = speaker
        self.config = config
        model.queue = Self.loadQueue()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async { self?.setOnline(ok) }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
        stateTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refreshState() }
        refreshState()
    }

    func reload(_ c: OrolConfig) {
        config = c
        quick?.stop(); quick = nil
        agent?.stop(); agent = nil
        refreshState()
    }

    func shutdown() {
        pathMonitor.cancel()
        quick?.stop(); agent?.stop()
        tasks.forEach { $0.stop() }
    }

    // MARK: availability

    private func setOnline(_ ok: Bool) {
        guard model.online != ok else { return }
        model.online = ok
        if ok, block == .unreachable { block = .none }
        if !ok {                                     // a warm process can't survive this; start fresh later
            if active == nil { quick?.stop(); quick = nil }
        }
        refreshState()
    }

    func refreshState() {
        if block != .none && Date() >= blockedUntil { block = .none }
        let s: ClaudeState
        if config.claudeExecutable() == nil { s = .missing }
        else if !model.online || forceOffline { s = .offline }
        else {
            switch block {
            case .limit: s = .limited(limitResetKnown ? blockedUntil : nil)
            case .login: s = .noLogin
            case .unreachable: s = .unreachable
            case .none: s = .ready
            }
        }
        let was = model.claude
        if s != was {
            model.claude = s
            olog("claude: \(s)")
            if s.isReady && !was.isReady {
                prewarm()
                if !model.queue.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.drainQueue() }
                }
            }
        }
        if s.isReady { drainQueue() }
    }

    private func setBlock(_ b: Block, until: Date, known: Bool = true) {
        block = b
        blockedUntil = until
        limitResetKnown = known
        if b != .none { quick?.stop(); quick = nil }
        refreshState()
    }

    /// What kind of failure an error text describes.
    private func classify(_ text: String, status: Int?) -> Block? {
        let low = text.lowercased()
        if status == 429 || ["usage limit", "rate limit", "limit reached", "hit your limit", "limit will reset",
                             "out of extra usage", "credit balance", "quota"].contains(where: low.contains) { return .limit }
        if status == 401 || status == 403 || ["login", "oauth", "not logged", "authenticat", "unauthorized"].contains(where: low.contains) {
            return .login
        }
        if ["enotfound", "econnrefused", "econnreset", "etimedout", "network", "fetch failed", "timed out",
            "socket", "getaddrinfo", "connection error", "unable to connect", "overloaded", "529"].contains(where: low.contains) {
            return .unreachable
        }
        return nil
    }

    private func apply(_ b: Block) {
        switch b {
        case .limit:
            if let r = lastReset, r > Date() { setBlock(.limit, until: r, known: true) }
            else { setBlock(.limit, until: Date().addingTimeInterval(15 * 60), known: false) }
        case .login: setBlock(.login, until: Date().addingTimeInterval(10 * 60))
        case .unreachable: setBlock(.unreachable, until: Date().addingTimeInterval(60))
        case .none: break
        }
    }

    /// Claude Code reports the plan's windows in its stream (`rate_limit_event`).
    func noteRate(_ e: [String: Any]) {
        guard e["type"] as? String == "rate_limit_event", let info = e["rate_limit_info"] as? [String: Any] else { return }
        if let w = info["unifiedWindows"] as? [String: Any] {
            if let u = (w["five_hour"] as? [String: Any])?["utilization"] as? Double { model.usage5h = u }
            if let u = (w["seven_day"] as? [String: Any])?["utilization"] as? Double { model.usage7d = u }
        }
        let status = info["status"] as? String ?? "allowed"
        let reset = (info["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        lastReset = reset
        if status == "rejected" {
            setBlock(.limit, until: reset ?? Date().addingTimeInterval(15 * 60), known: reset != nil)
        }
    }

    // MARK: queue

    private static var queueURL: URL { Paths.support.appendingPathComponent("queue.json") }

    private static func loadQueue() -> [QueuedAsk] {
        guard let d = try? Data(contentsOf: queueURL), let q = try? JSONDecoder().decode([QueuedAsk].self, from: d) else { return [] }
        return q
    }

    private func saveQueue() {
        if let d = try? JSONEncoder().encode(model.queue) { try? d.write(to: Self.queueURL, options: .atomic) }
    }

    private func enqueue(_ text: String) {
        guard !model.queue.contains(where: { $0.answer == nil && $0.question == text }) else { return }
        model.queue.append(QueuedAsk(question: text))
        if model.queue.count > 20 { model.queue.removeFirst(model.queue.count - 20) }
        saveQueue()
    }

    func removeQueued(_ id: UUID) {
        if background == id { cancelActive(); background = nil }
        model.queue.removeAll { $0.id == id }
        saveQueue()
    }

    /// Show a queued answer in the panel.
    func showQueued(_ item: QueuedAsk) {
        removeQueued(item.id)
        currentQuestion = item.question
        model.question = item.question
        model.answer = item.answer ?? ""
        model.status = ""
        model.inputText = ""
        model.phase = .done
        doneAt = Date()
        if let a = item.answer { history.append((item.question, a)) }
    }

    /// The reply when Claude can't take the request now: say why, keep the question.
    private func deferred(_ text: String) -> String {
        let why: String
        switch model.claude {
        case .offline: why = "Internet yoʻq."
        case .limited(let d): why = d.map { "Claude limiti tugadi, \(friendlyTime($0)) tiklanadi." } ?? "Claude limiti tugadi."
        case .noLogin: why = "Claude hisobiga kirilmagan (terminalda: claude auth login)."
        case .unreachable: why = "Claude hozir javob bermayapti."
        case .missing: return "claude buyrugʻi topilmadi. Claude Code oʻrnatilganini tekshiring yoki config.json ichida claudePath ni koʻrsating."
        case .ready: why = "Claude javob bermadi."
        }
        enqueue(text)
        return why + " Savolingizni navbatga qoʻydim, Claude qaytishi bilan javob beraman. "
            + "Hozir ham taymer, hisob-kitob, musiqa, ovoz va ilova ochish ishlaydi (“yordam” deb yozing)."
    }

    /// Answer the oldest waiting question in the background, one at a time.
    func drainQueue() {
        guard background == nil, active == nil, model.phase == .idle, model.approvals.isEmpty,
              model.claude.isReady, let item = model.queue.first(where: { $0.answer == nil }) else { return }
        background = item.id
        generation += 1
        byVoice = false
        currentQuestion = item.question
        buffer = ""
        if let (name, path, task) = explicitTask(item.question) {
            startTask(project: name, path: path, task: task)
            return
        }
        if Self.needsTools(item.question) { escalate(); return }
        if quick == nil { quick = makeQuick() }
        active = .quick
        quick?.send(item.question)
        armWatchdog(60)
    }

    // MARK: routing

    /// Requests that clearly need tools, personal data or live information go straight to
    /// the agent; the tool-less quick model sometimes answers "I can't access that" instead.
    static func needsTools(_ text: String) -> Bool {
        let t = LocalBrain.normalize(text)
        let keys = ["notion", "kalendar", "calendar", "taqvim", "uchrashuv", "gmail", "pochta", "email", "e-mail",
                    "xat kel", "drive", "telegram", "slack", "fayl", "papka", "file", "folder", "sahifam", "jurnalim",
                    "yangilik", "news", "ob-havo", "obhavo", "weather", "havo qanday", "dollar", "kurs qancha",
                    "narxi", "price", "bugungi", "hozirgi", "latest", "internetdan", "qidir", "search", "google",
                    "youtube", "instagram", "kanalim", "my notes", "my calendar", "my email", "eslatmalarim",
                    "rejam", "vazifalarim", "github"]
        return keys.contains(where: t.contains)
    }

    /// The quick model said it has no access instead of asking for a lookup.
    static func soundsLikeNoAccess(_ text: String) -> Bool {
        let t = LocalBrain.normalize(text)
        let keys = ["kirish imkon", "ulana olmayman", "ulanish imkon", "kira olmayman", "ko'ra olmayman",
                    "real vaqt", "internetga kir", "ma'lumotga ega emasman", "ma'lumotim yo'q", "can't access",
                    "cannot access", "don't have access", "do not have access", "no access", "real-time",
                    "browse", "нет доступа", "не могу получить доступ"]
        return keys.contains(where: t.contains)
    }

    // MARK: processes

    private var quickPrompt: String {
        var s = """
        You are Orol, a small assistant that lives in the notch of the user's Mac. Answer in the \
        language the user writes in (often Uzbek), in one to three short sentences of plain text: \
        no markdown, no lists, no emoji (cards and code blocks described below are the only exception). Answer general-knowledge questions yourself from what you \
        know: facts, numbers, maths, definitions, translations, explanations, advice, code. You have \
        no tools here. Reply with exactly LOOKUP and nothing else only when the request truly needs \
        one of these: the user's own data (their notes, Notion, calendar, email, files, projects), \
        live information (today's news, weather, prices, scores, anything after your training), or \
        an action on the computer or in an app.
        """ + " " + CardParse.prompt
        let names = config.projects.keys.sorted()
        if !names.isEmpty {
            s += " If the user asks to start work or a task in one of these projects (" + names.joined(separator: ", ")
                + "), reply with exactly: TASK <project name> :: <the task, restated clearly> and nothing else."
        }
        return s
    }

    private func makeQuick() -> ClaudeProcess? {
        guard let exe = config.claudeExecutable() else { return nil }
        let p = ClaudeProcess(executable: exe, args: [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--model", config.quickModel, "--tools", "",
            "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
            "--system-prompt", quickPrompt,
        ], env: OrolConfig.childEnvironment(internalKind: "quick"), cwd: Paths.work)
        p.onEvent = { [weak self] e in self?.event(e, from: .quick) }
        p.onExit = { [weak self] code in self?.exited(.quick, code) }
        return p
    }

    private func makeAgent() -> ClaudeProcess? {
        guard let exe = config.claudeExecutable() else { return nil }
        HookInstaller.installRelay()
        var args = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--model", config.agentModel, "--name", "Orol",
            "--settings", HookInstaller.ownHookSettings(),
            "--append-system-prompt", """
            You are answering through Orol, a small island in the notch of the user's Mac. The final \
            answer is shown in a small panel and may be read aloud: one to four short sentences of \
            plain text in the user's language, no markdown, no lists. Use your tools and connectors \
            to look things up. Do not run session-start routines here; just answer the request.
            """ + " " + CardParse.prompt,
        ]
        if !config.agentAllowedTools.isEmpty {
            args += ["--allowedTools", config.agentAllowedTools.joined(separator: ",")]
        }
        let p = ClaudeProcess(executable: exe, args: args,
                              env: OrolConfig.childEnvironment(internalKind: "agent"), cwd: Paths.work)
        p.onEvent = { [weak self] e in self?.event(e, from: .agent) }
        p.onExit = { [weak self] code in self?.exited(.agent, code) }
        return p
    }

    /// Start the quick process ahead of the first question (only when Claude can answer).
    func prewarm() {
        guard model.claude.isReady else { return }
        if quick == nil { quick = makeQuick() }
        quick?.start()
    }

    // MARK: a request

    func submit(_ raw: String, byVoice: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancelActive()
        background = nil
        generation += 1
        self.byVoice = byVoice
        currentQuestion = text
        buffer = ""
        speaker.stop()
        model.question = text
        model.answer = ""
        model.status = ""
        model.inputText = ""
        model.phase = .thinking

        // 1. The island's own commands: instant, offline, no limit.
        let gen = generation
        if let reply = LocalBrain.handle(text, model: model, claudeReady: model.claude.isReady, config: config,
                                         later: { [weak self] answer, card in
                                             guard let self, self.generation == gen, self.background == nil,
                                                   self.model.phase == .thinking else { return }
                                             if let card { self.model.card = card }
                                             self.finish(answer, record: false)
                                         }) {
            if reply != LocalBrain.pending { finish(reply, record: false) }
            return
        }
        // 2. Claude, when it can answer; otherwise the question waits.
        refreshState()
        guard model.claude.isReady else {
            finish(deferred(text), record: false)
            return
        }
        if let (name, path, task) = explicitTask(text) {
            startTask(project: name, path: path, task: task)
            return
        }
        if Self.needsTools(text) { escalate(); return }
        if quick == nil { quick = makeQuick() }
        active = .quick
        quick?.send(text)
        armWatchdog(40)
    }

    private func armWatchdog(_ seconds: Double) {
        watchdog?.cancel()
        let gen = generation
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen, let tier = self.active else { return }
            self.cancelActive()
            if !self.ui {
                self.background = nil
                if tier == .quick { self.apply(.unreachable) }
                return
            }
            if tier == .quick {
                self.apply(.unreachable)
                self.finish(self.deferred(self.currentQuestion), record: false)
            } else {
                self.finish("Javob juda uzoq kutildi. Qayta urinib koʻring.", record: false)
            }
        }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func cancelActive() {
        watchdog?.cancel()
        guard let tier = active else { return }
        active = nil
        switch tier {
        case .quick:
            quick?.stop(); quick = nil            // cheap to restart; drops the half-made turn
        case .agent:
            agent?.interrupt()
        }
    }

    /// The user closed the panel or pressed stop.
    func cancel() {
        cancelActive()
        background = nil
        generation += 1
        speaker.stop()
    }

    private func exited(_ tier: Tier, _ code: Int32) {
        if tier == .quick { quick = nil } else { agent = nil }
        guard active == tier else { return }
        active = nil
        watchdog?.cancel()
        if !ui { background = nil; return }
        if !model.online || !model.claude.isReady {
            finish(deferred(currentQuestion), record: false)
        } else {
            finish("Claude jarayoni toʻxtab qoldi (kod \(code)). Terminalda `claude auth status` ni tekshiring.", record: false)
        }
    }

    private func event(_ e: [String: Any], from tier: Tier) {
        let type = e["type"] as? String ?? ""
        if type == "rate_limit_event" { noteRate(e); return }
        guard active == tier else { return }
        switch type {
        case "stream_event":
            guard let ev = e["event"] as? [String: Any], e["parent_tool_use_id"] is NSNull || e["parent_tool_use_id"] == nil else { return }
            let et = ev["type"] as? String ?? ""
            if et == "message_start" {
                buffer = ""                              // a new assistant message: only the last one is the answer
            } else if et == "content_block_start", let cb = ev["content_block"] as? [String: Any],
                      cb["type"] as? String == "tool_use" {
                toolStarted(cb["name"] as? String ?? "")
            } else if et == "content_block_delta", let d = ev["delta"] as? [String: Any],
                      d["type"] as? String == "text_delta", let t = d["text"] as? String {
                buffer += t
                streamed()
            }
        case "result":
            watchdog?.cancel()
            active = nil
            let isError = e["is_error"] as? Bool ?? false
            var text = (e["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { text = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
            if isError {
                let status = e["api_error_status"] as? Int
                if let b = classify(text, status: status) {
                    apply(b)
                    if !ui { background = nil; return }
                    finish(deferred(currentQuestion), record: false)
                    return
                }
                if !ui { background = nil; return }
                finish(text.isEmpty ? "Xatolik yuz berdi." : text, record: false)
                return
            }
            if block != .none { setBlock(.none, until: .distantPast) }
            if tier == .quick {
                if text == "LOOKUP" || Self.soundsLikeNoAccess(text) { escalate(); return }
                if text.hasPrefix("TASK "), let t = parseTaskLine(text) {
                    startTask(project: t.0, path: t.1, task: t.2)
                    return
                }
            }
            finish(text.isEmpty ? "Javob boʻsh keldi." : text, record: true)
        default:
            break
        }
    }

    /// Control words from the quick model are never shown.
    private func isControlPrefix(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        return "LOOKUP".hasPrefix(t) || "TASK ".hasPrefix(t) || t.hasPrefix("TASK ")
    }

    private func streamed() {
        guard ui else { return }
        if active == .quick && isControlPrefix(buffer) { return }
        let text = CardParse.split(buffer).0
        guard !text.isEmpty else { return }
        model.answer = text
        if model.phase == .thinking { model.phase = .answering }
        if shouldSpeak { speaker.feed(text) }
    }

    private func toolStarted(_ name: String) {
        guard !name.isEmpty else { return }
        buffer = ""
        armWatchdog(180)
        guard ui else { return }
        let d = SessionHub.describe(name, [:])
        model.status = d.title
        model.answer = ""
        speaker.stop()
        if model.phase == .answering { model.phase = .thinking }
    }

    private var shouldSpeak: Bool {
        ui && (config.speak == "always" || (config.speak == "voice" && byVoice))
    }

    private func escalate() {
        if agent == nil { agent = makeAgent() }
        guard let agent else { finish("Agentni ishga tushirib boʻlmadi.", record: false); return }
        buffer = ""
        if ui {
            model.status = "Qidiryapman…"
            model.phase = .thinking
        }
        active = .agent
        var message = currentQuestion
        let recent = history.suffix(3)
        if ui, !recent.isEmpty {
            let ctx = recent.map { "User: \($0.q)\nOrol: \($0.a)" }.joined(separator: "\n")
            message = "Earlier in this conversation:\n\(ctx)\n\nNow answer this request: \(currentQuestion)"
        }
        agent.send(message)
        armWatchdog(180)
    }

    private func finish(_ raw: String, record: Bool) {
        let (text, cards) = CardParse.split(raw)
        if background == nil { for c in cards { model.card = c } }
        active = nil
        watchdog?.cancel()
        if let id = background {
            // A queued question got its answer: keep it, and tell the user it's there.
            background = nil
            if let i = model.queue.firstIndex(where: { $0.id == id }) {
                model.queue[i].answer = text
                model.queue[i].answered = Date()
                saveQueue()
                model.showFlash(Flash(icon: "tray.full.fill", left: "Javob tayyor",
                                      right: SessionHub.oneLine(model.queue[i].question, 22), tint: emberColor), seconds: 5)
                if config.sounds { NSSound(named: "Pop")?.play() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.drainQueue() }
            return
        }
        model.answer = text
        model.status = ""
        model.phase = .done
        doneAt = Date()
        if record {
            history.append((currentQuestion, text))
            if history.count > 12 { history.removeFirst(history.count - 12) }
        }
        if shouldSpeak { speaker.finish(text) }
    }

    // MARK: tasks (tier c)

    private func resolveProject(_ name: String) -> (String, String)? {
        let want = name.lowercased().trimmingCharacters(in: .whitespaces)
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        for (k, v) in config.projects where k.lowercased() == want || norm(k) == norm(want) {
            return (k, Paths.expand(v))
        }
        return nil
    }

    /// "vazifa orol: readme yoz" / "task orol: write the readme"
    private func explicitTask(_ text: String) -> (String, String, String)? {
        let pattern = #"^(?:vazifa|task|start a task in)\s+(.+?)\s*:\s*(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text),
              let (name, path) = resolveProject(String(text[r1])) else { return nil }
        return (name, path, String(text[r2]))
    }

    private func parseTaskLine(_ line: String) -> (String, String, String)? {
        let body = line.dropFirst(5)
        guard let sep = body.range(of: "::"),
              let (name, path) = resolveProject(String(body[..<sep.lowerBound])) else { return nil }
        let task = body[sep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return task.isEmpty ? nil : (name, path, task)
    }

    private func startTask(project: String, path: String, task: String) {
        guard let exe = config.claudeExecutable() else { finish("claude buyrugʻi topilmadi.", record: false); return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            finish("“\(project)” loyihasining papkasi topilmadi: \(path)", record: false)
            return
        }
        HookInstaller.installRelay()
        var args = ["-p", task, "--output-format", "stream-json", "--verbose",
                    "--permission-mode", config.taskPermissionMode,
                    "--name", "orol: " + SessionHub.oneLine(task, 60),
                    "--settings", HookInstaller.ownHookSettings(),
                    "--append-system-prompt",
                    "This task was started from Orol, the island in the user's Mac notch. Do only this task, on your own, inside this project folder. Do not run session-start routines or update notes elsewhere. End your final message with a line 'SUMMARY: <one sentence, in the language of the task>'."]
        if !config.taskModel.isEmpty { args += ["--model", config.taskModel] }
        let p = ClaudeProcess(executable: exe, args: args, env: OrolConfig.childEnvironment(internalKind: "task"),
                              cwd: URL(fileURLWithPath: path), interactive: false)
        var sid = ""
        var finished = false
        p.onEvent = { [weak self, weak p] e in
            guard let self else { return }
            let type = e["type"] as? String ?? ""
            if type == "rate_limit_event" { self.noteRate(e); return }
            if type == "system", e["subtype"] as? String == "init", let s = e["session_id"] as? String, sid.isEmpty {
                sid = s
                self.hub.taskStarted(sid: s, cwd: path, title: task)
                if self.model.phase != .idle, self.model.question.contains(task) || self.model.answer.contains(project) {
                    self.model.card = .task(s)
                }
            } else if type == "assistant", !sid.isEmpty, let msg = e["message"] as? [String: Any],
                      let content = msg["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "tool_use" {
                    self.hub.taskTool(sid: sid, tool: block["name"] as? String ?? "",
                                      input: block["input"] as? [String: Any] ?? [:])
                }
            } else if type == "result", !sid.isEmpty {
                finished = true
                let failed = e["is_error"] as? Bool ?? false
                let text = e["result"] as? String ?? ""
                var summary = SessionHub.oneLine(text, 200)
                if let r = text.range(of: "SUMMARY:", options: .backwards) {
                    summary = SessionHub.oneLine(String(text[r.upperBound...]), 200)
                }
                self.hub.taskFinished(sid: sid, summary: summary, failed: failed)
                if self.config.speak == "always" { self.speaker.finish(summary) }
                if let p { self.tasks.removeAll { $0 === p } }
            }
        }
        p.onExit = { [weak self, weak p] code in
            guard let self else { return }
            if !finished, !sid.isEmpty { self.hub.taskFinished(sid: sid, summary: "Jarayon toʻxtadi (kod \(code)).", failed: true) }
            if let p { self.tasks.removeAll { $0 === p } }
        }
        tasks.append(p)
        p.start()
        finish("“\(project)” loyihasida vazifa boshlandi. Holatini orolda kuzatib borasiz.", record: true)
    }
}
