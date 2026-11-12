import AppKit
import SwiftUI

/// Turns hook events into session rows, tickers, approval cards and "done" moments.
final class SessionHub {
    private let model: IslandModel
    private let config: () -> OrolConfig
    private struct Pending {
        let connection: HookServer.Connection
        let timeout: DispatchWorkItem
        let sessionId: String
        let tool: String
    }
    private var pending: [UUID: Pending] = [:]
    private var sweep: Timer?
    static let approvalTimeout: TimeInterval = 108      // relay 110 s, hook 120 s
    static let maxPending = 5

    init(model: IslandModel, config: @escaping () -> OrolConfig) {
        self.model = model
        self.config = config
        sweep = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.sweepStale() }
    }

    // MARK: events

    func handle(_ m: HookServer.Message) {
        let p = m.payload
        let sid = p["session_id"] as? String ?? ""
        guard !sid.isEmpty else { m.connection?.close(); return }
        let cwd = p["cwd"] as? String ?? ""
        let tool = p["tool_name"] as? String ?? ""
        let input = p["tool_input"] as? [String: Any] ?? [:]
        let fromOrol = !m.internalKind.isEmpty

        // Orol's own agent only ever sends its approvals; it never becomes a session row.
        if !(fromOrol && m.internalKind == "agent") {
            touch(sid, cwd: cwd, env: m.env)
        }

        switch m.event {
        case "SessionStart":
            break
        case "UserPromptSubmit":
            update(sid) {
                $0.prompt = Self.oneLine(p["prompt"] as? String ?? "", 120)
                $0.status = .working
                $0.turnStarted = Date()
                $0.ticker = ""
                $0.summary = ""
                $0.steps = []
            }
            settle(sid)
        case "PreToolUse":
            update(sid) {
                $0.status = .working
                $0.ticker = Self.describe(tool, input).ticker
                Self.addStep(&$0, $0.ticker)
            }
        case "PostToolUse", "PostToolUseFailure":
            let (plus, minus) = Self.editCounts(tool, input)
            update(sid) {
                if $0.status != .working { $0.status = .working }
                $0.plus += plus
                $0.minus += minus
            }
            settle(sid, tool: tool)
        case "PermissionRequest":
            guard let conn = m.connection else { return }
            addApproval(sid: sid, cwd: cwd, tool: tool, input: input, payload: p, conn: conn, fromOrol: fromOrol)
        case "Notification":
            let msg = (p["message"] as? String ?? "").lowercased()
            if msg.contains("permission") || msg.contains("waiting") || msg.contains("input") {
                update(sid) { if $0.status == .working || $0.status == .idle { $0.status = .waiting } }
            }
        case "Stop", "StopFailure":
            let failed = (m.event == "StopFailure")
            let last = Self.oneLine(p["last_assistant_message"] as? String ?? "", 160)
            var announce: SessionInfo?
            update(sid) {
                let wasBusy = ($0.status == .working || $0.status == .waiting)
                $0.status = failed ? .failed : .done
                $0.ticker = ""
                if !last.isEmpty { $0.summary = last }
                if wasBusy && !$0.isTask { announce = $0 }
            }
            settle(sid)
            if let s = announce { announceDone(s, failed: failed) }
        case "SubagentStart":
            update(sid) { $0.subagents += 1 }
        case "SubagentStop":
            update(sid) { $0.subagents = max(0, $0.subagents - 1) }
        case "SessionEnd":
            settle(sid)
            model.sessions.removeAll { $0.id == sid }
        default:
            break
        }
    }

    private func touch(_ sid: String, cwd: String, env: [String: String]) {
        if let i = model.sessions.firstIndex(where: { $0.id == sid }) {
            model.sessions[i].lastEvent = Date()
            if !cwd.isEmpty { model.sessions[i].cwd = cwd }
            if let t = env["term_bundle"], !t.isEmpty { model.sessions[i].termBundle = t }
            return
        }
        var s = SessionInfo(id: sid, cwd: cwd)
        s.termBundle = env["term_bundle"] ?? ""
        s.entrypoint = env["entrypoint"] ?? ""
        model.sessions.append(s)
    }

    private func update(_ sid: String, _ f: (inout SessionInfo) -> Void) {
        guard let i = model.sessions.firstIndex(where: { $0.id == sid }) else { return }
        var s = model.sessions[i]
        f(&s)
        s.lastEvent = Date()
        if s != model.sessions[i] { model.sessions[i] = s }
    }

    private func announceDone(_ s: SessionInfo, failed: Bool) {
        guard model.phase == .idle else { return }
        model.showFlash(Flash(icon: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                              left: s.project, right: failed ? "xato" : "tugadi",
                              tint: failed ? .red : .green))
        if config().sounds { NSSound(named: failed ? "Basso" : "Glass")?.play() }
    }

    private func sweepStale() {
        let now = Date()
        model.sessions.removeAll {
            ($0.status == .done || $0.status == .failed || $0.status == .idle) && now.timeIntervalSince($0.lastEvent) > 20 * 60
        }
        for i in model.sessions.indices where model.sessions[i].status == .working
            && now.timeIntervalSince(model.sessions[i].lastEvent) > 15 * 60 {
            model.sessions[i].status = .idle
        }
    }

    // MARK: tasks started by Orol (tracked from their own stream)

    func taskStarted(sid: String, cwd: String, title: String) {
        touch(sid, cwd: cwd, env: [:])
        update(sid) { $0.isTask = true; $0.prompt = title; $0.status = .working; $0.turnStarted = Date() }
    }

    func taskTool(sid: String, tool: String, input: [String: Any]) {
        update(sid) {
            $0.ticker = Self.describe(tool, input).ticker
            Self.addStep(&$0, $0.ticker)
        }
    }

    static func addStep(_ s: inout SessionInfo, _ step: String) {
        guard !step.isEmpty, s.steps.last != step else { return }
        s.steps.append(step)
        if s.steps.count > 8 { s.steps.removeFirst(s.steps.count - 8) }
    }

    func taskFinished(sid: String, summary: String, failed: Bool) {
        var info: SessionInfo?
        update(sid) {
            $0.status = failed ? .failed : .done
            $0.ticker = ""
            $0.summary = summary
            info = $0
        }
        settle(sid)
        if let s = info {
            model.showFlash(Flash(icon: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                  left: s.project, right: failed ? "xato" : "vazifa tugadi",
                                  tint: failed ? .red : .green), seconds: 4)
            if config().sounds { NSSound(named: failed ? "Basso" : "Glass")?.play() }
        }
    }

    // MARK: approvals

    private func addApproval(sid: String, cwd: String, tool: String, input: [String: Any],
                             payload: [String: Any], conn: HookServer.Connection, fromOrol: Bool) {
        guard pending.count < Self.maxPending else { conn.close(); return }     // overflow: the terminal asks
        let d = Self.describe(tool, input)
        var card = ApprovalCard(sessionId: sid,
                                project: fromOrol && cwd == Paths.work.path ? "Orol" : ((cwd as NSString).lastPathComponent),
                                tool: tool, title: d.title, detail: d.detail,
                                dangerous: Self.isDangerous(tool, input, cwd: cwd),
                                canAlways: !((payload["permission_suggestions"] as? [Any]) ?? []).isEmpty,
                                fromOrol: fromOrol)
        if tool == "AskUserQuestion" {
            card.questions = Self.parseQuestions(input)
            if card.questions.isEmpty || card.questions.contains(where: { $0.options.count < 2 }) {
                conn.close(); return                                             // leave it to the terminal
            }
            card.title = "Savol"
        }
        if card.dangerous { card.canAlways = false }
        let id = card.id
        let timeout = DispatchWorkItem { [weak self] in self?.drop(id, close: true) }
        pending[id] = Pending(connection: conn, timeout: timeout, sessionId: sid, tool: tool)
        conn.onPeerClosed = { [weak self] in self?.drop(id, close: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.approvalTimeout, execute: timeout)
        update(sid) { $0.status = .waiting }
        model.approvals.append(card)
        if config().sounds { NSSound(named: "Tink")?.play() }
    }

    /// kind: "allow" | "deny" | "always" | "pass" | "answers"
    func decide(_ card: ApprovalCard, kind: String, answers: [String: String]) {
        guard let p = pending.removeValue(forKey: card.id) else {
            model.approvals.removeAll { $0.id == card.id }
            return
        }
        p.timeout.cancel()
        model.approvals.removeAll { $0.id == card.id }
        switch kind {
        case "pass":
            p.connection.close()
        case "answers":
            p.connection.reply(["reply": "answers", "answers": answers])
        default:
            p.connection.reply(["reply": kind])
        }
        if kind != "pass" { update(p.sessionId) { $0.status = .working } }
    }

    private func drop(_ id: UUID, close: Bool) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.timeout.cancel()
        if close { p.connection.close() }
        model.approvals.removeAll { $0.id == id }
    }

    /// The request was answered elsewhere (the terminal), or the turn moved on.
    private func settle(_ sid: String, tool: String? = nil) {
        for (id, p) in pending where p.sessionId == sid && (tool == nil || p.tool == tool) {
            drop(id, close: true)
        }
    }

    // MARK: describing tools

    static func oneLine(_ s: String, _ cap: Int) -> String {
        let t = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return t.count > cap ? String(t.prefix(cap - 1)) + "…" : t
    }

    static func mcpParts(_ tool: String) -> (service: String, action: String)? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return nil }
        var service = parts[0]
        for prefix in ["claude_ai_", "plugin_"] where service.hasPrefix(prefix) { service = String(service.dropFirst(prefix.count)) }
        service = service.replacingOccurrences(of: "_", with: " ")
        var action = parts[1...].joined(separator: " ")
        let low = service.lowercased().replacingOccurrences(of: " ", with: "")
        for sep in ["-", "_"] where action.lowercased().hasPrefix(low + sep) { action = String(action.dropFirst(low.count + 1)) }
        action = action.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return (service.prefix(1).uppercased() + service.dropFirst(), action.lowercased())
    }

    static func describe(_ tool: String, _ input: [String: Any]) -> (ticker: String, title: String, detail: String) {
        func str(_ k: String) -> String { input[k] as? String ?? "" }
        func file(_ k: String = "file_path") -> String { (str(k) as NSString).lastPathComponent }
        switch tool {
        case "Bash":
            let c = str("command")
            return ("Buyruq · " + oneLine(c, 60), "Buyruq", c)
        case "Edit", "MultiEdit", "NotebookEdit":
            let path = str("file_path").isEmpty ? str("notebook_path") : str("file_path")
            return ("Tahrir · " + (path as NSString).lastPathComponent, "Tahrir · " + (path as NSString).lastPathComponent, path)
        case "Write":
            return ("Yozish · " + file(), "Yozish · " + file(), str("file_path"))
        case "Read":
            return ("Oʻqish · " + file(), "Oʻqish · " + file(), str("file_path"))
        case "Grep", "Glob":
            return ("Qidiruv · " + oneLine(str("pattern"), 50), "Qidiruv", str("pattern"))
        case "WebSearch":
            return ("Internet · " + oneLine(str("query"), 50), "Internet qidiruvi", str("query"))
        case "WebFetch":
            let host = URL(string: str("url"))?.host ?? str("url")
            return ("Internet · " + host, "Sahifani ochish", str("url"))
        case "Task", "Agent":
            return ("Agent · " + oneLine(str("description"), 50), "Agent", str("description"))
        case "TodoWrite":
            return ("Reja yangilanmoqda", "Reja", "")
        case "ExitPlanMode":
            return ("Reja tayyor", "Rejani tasdiqlash", oneLine(str("plan"), 600))
        case "AskUserQuestion":
            return ("Savol beryapti", "Savol", "")
        default:
            var detail = ""
            if !input.isEmpty, let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
               let s = String(data: d, encoding: .utf8) { detail = String(s.prefix(600)) }
            if let m = mcpParts(tool) {
                return ("\(m.service) · \(m.action)", "\(m.service) · \(m.action)", detail)
            }
            return (tool, tool, detail)
        }
    }

    static func editCounts(_ tool: String, _ input: [String: Any]) -> (Int, Int) {
        func lines(_ s: String) -> Int { s.isEmpty ? 0 : s.split(whereSeparator: \.isNewline).count }
        switch tool {
        case "Edit":
            return (lines(input["new_string"] as? String ?? ""), lines(input["old_string"] as? String ?? ""))
        case "MultiEdit":
            var p = 0, m = 0
            for e in input["edits"] as? [[String: Any]] ?? [] {
                p += lines(e["new_string"] as? String ?? ""); m += lines(e["old_string"] as? String ?? "")
            }
            return (p, m)
        case "Write":
            return (lines(input["content"] as? String ?? ""), 0)
        default:
            return (0, 0)
        }
    }

    /// Flags the request so the card shows a warning and never offers "Doim".
    static func isDangerous(_ tool: String, _ input: [String: Any], cwd: String) -> Bool {
        if tool == "Bash" {
            let c = (input["command"] as? String ?? "").lowercased()
            let patterns = [#"\brm\s+(-[a-z]*[rf][a-z]*\s+)"#, #"\bsudo\b"#, #"git\s+push\b.*(--force|\s-f\b)"#,
                            #"git\s+reset\s+--hard"#, #"git\s+clean\s+-[a-z]*f"#, #"(curl|wget)[^|;&]*\|\s*(ba|z)?sh"#,
                            #"\bmkfs\b"#, #"\bdd\s+if="#, #"chmod\s+-r\b"#, #">\s*/dev/(disk|sd)"#, #"\bdiskutil\s+erase"#,
                            #"\.ssh/"#, #"\bkillall\b"#, #"\bshutdown\b"#, #"\breboot\b"#, #"\bdefaults\s+delete\b"#]
            return patterns.contains { c.range(of: $0, options: .regularExpression) != nil }
        }
        if ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool) {
            let path = Paths.expand(input["file_path"] as? String ?? input["notebook_path"] as? String ?? "")
            let low = path.lowercased()
            if !cwd.isEmpty, path.hasPrefix("/"), !path.hasPrefix(cwd) { return true }
            for s in ["/.ssh/", "/.env", "/.claude/settings", "credentials", "/.aws/", "/.zshrc", "/.bash_profile", "keychain"]
            where low.contains(s) { return true }
            return false
        }
        if let m = mcpParts(tool) {
            for w in ["send", "delete", "remove", "archive", "publish", "cancel", "trash"] where m.action.contains(w) { return true }
        }
        return false
    }

    static func parseQuestions(_ input: [String: Any]) -> [Question] {
        (input["questions"] as? [[String: Any]] ?? []).compactMap { q in
            guard let text = q["question"] as? String else { return nil }
            let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> QuestionOption? in
                guard let l = o["label"] as? String else { return nil }
                return QuestionOption(label: l, detail: o["description"] as? String ?? "")
            }
            return Question(text: text, header: q["header"] as? String ?? "", options: opts,
                            multi: q["multiSelect"] as? Bool ?? false)
        }
    }

    // MARK: jump

    static func jump(to s: SessionInfo) {
        var ids: [String] = []
        if s.entrypoint.contains("desktop") { ids.append("com.anthropic.claudefordesktop") }
        if !s.termBundle.isEmpty { ids.append(s.termBundle) }
        ids += ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                "com.microsoft.VSCode", "com.anthropic.claudefordesktop"]
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }
}
