import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = OrolConfig.load()
    private let model = IslandModel()
    private var window: IslandWindowController!
    private var server = HookServer()
    private var hub: SessionHub!
    private var assistant: Assistant!
    private let speaker = Speaker()
    private var speech: VoiceInput = SpeechInput()
    private let whisper = WhisperServer()
    private var usingWhisper = false
    private let wake = WakeListener()
    private var wakePauseWork: DispatchWorkItem?
    private var nowPlaying: NowPlaying!
    private var battery: BatteryMonitor!
    private var timerClock: TimerClock!
    private var alerts: SystemAlerts!
    private let hotkey = Hotkey()
    private var statusItem: NSStatusItem!
    private var linger: Timer?
    private var voiceRequest = false

    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ note: Notification) {
        WhisperServer.reapOrphan()
        // `kill`/`pkill` sends SIGTERM, which skips applicationWillTerminate: stop the helpers anyway.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term
        do {
            try server.start()
        } catch HookServer.StartError.alreadyRunning {
            olog("Orol is already running; quitting this copy")
            NSApp.terminate(nil)
            return
        } catch {
            olog("hook server failed: \(error)")
        }

        hub = SessionHub(model: model) { [weak self] in self?.config ?? OrolConfig() }
        server.handler = { [weak self] m in self?.hub.handle(m) }
        assistant = Assistant(model: model, hub: hub, speaker: speaker, config: config)
        window = IslandWindowController(model: model)
        nowPlaying = NowPlaying(model: model)
        battery = BatteryMonitor(model: model)
        timerClock = TimerClock(model: model) { [weak self] in self?.config.sounds ?? true }
        alerts = SystemAlerts(model: model)

        HookInstaller.installRelay()
        model.hooksInstalled = HookInstaller.isInstalled()

        wireModel()
        selectVoiceEngine()
        setupWake()
        registerHotkey()
        buildStatusItem()

        linger = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.lingerTick() }
        if ProcessInfo.processInfo.environment["OROL_DEBUG"] != nil { installDebugSignals() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.assistant.prewarm() }
        olog("accessibility trusted: \(AXMedia.trusted)")
        olog("Orol started (notch \(Int(model.notch.width))x\(Int(model.notch.height)), hasNotch \(model.hasNotch))")
    }

    func applicationWillTerminate(_ note: Notification) {
        assistant?.shutdown()
        speech.stop(commit: false)
        speaker.uzbek.shutdown()
        whisper.stop()
        wake.stop()
        server.stop()
    }

    // MARK: wiring

    private func wireModel() {
        model.onSubmit = { [weak self] text, byVoice in
            guard let self else { return }
            let spoken = byVoice || self.voiceRequest
            self.voiceRequest = false
            self.speech.stop(commit: false)
            self.assistant.submit(text, byVoice: spoken)
        }
        model.onOpenInput = { [weak self] mic in self?.openInput(mic: mic) }
        model.onDismiss = { [weak self] in self?.dismiss("button/esc/click") }
        model.onToggleMic = { [weak self] in
            guard let self else { return }
            if self.model.micOn { self.speech.stop(commit: false) } else { self.startMic() }
        }
        model.onStop = { [weak self] in
            guard let self else { return }
            self.assistant.cancel()
            if self.model.phase == .thinking || self.model.phase == .answering {
                self.model.status = ""
                self.model.phase = self.model.answer.isEmpty ? .input : .done
            }
        }
        model.onDecide = { [weak self] card, kind, answers in
            guard let self else { return }
            self.hub.decide(card, kind: kind, answers: answers)
            if self.model.approvals.isEmpty && self.model.phase == .idle { self.window.resetHover() }
        }
        model.onMedia = { [weak self] action in self?.nowPlaying.control(action) }
        model.onJump = { s in SessionHub.jump(to: s) }
        model.onCancelTimer = { [weak self] t in self?.model.timers.removeAll { $0.id == t.id } }
        model.onInstallHooks = { [weak self] in self?.toggleHooks() }
        model.onDropFiles = { [weak self] urls in
            guard let self else { return }
            self.openInput(mic: false)
            let paths = urls.map { "\"\($0.path)\"" }.joined(separator: " ")
            self.model.inputText = (self.model.inputText.isEmpty ? "" : self.model.inputText + " ") + paths + " "
        }
        speaker.onState = { [weak self] on in
            guard let self else { return }
            self.model.speaking = on
            if on { self.wake.suspend() } else if !self.model.micOn { self.wake.resume() }
        }
        model.onPauseListening = { [weak self] seconds in self?.pauseWake(seconds) }
        model.onNotMe = { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.wake.suspend()
            self.wake.resume(after: 3)
        }
        model.onOpenQueued = { [weak self] item in
            guard let self else { return }
            self.assistant.showQueued(item)
            self.window.takeKey()
            self.model.focusToken += 1
        }
        model.onRemoveQueued = { [weak self] item in self?.assistant.removeQueued(item.id) }
        model.onOpenActivity = { [weak self] a in
            guard let self else { return }
            switch a {
            case .media(let m)?:
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: m.bundleId).first {
                    app.activate()
                }
            case .waiting(let s)?: SessionHub.jump(to: s)
            case .working(let s)?: if let first = s.first { SessionHub.jump(to: first) }
            case .answers?: if let q = self.model.answeredQueue.first { self.model.onOpenQueued(q) }
            default: self.model.hovering = true
            }
        }
        model.onBargeIn = { [weak self] in
            guard let self else { return }
            self.assistant.cancel()
            self.model.phase = .idle
            Levels.shared.wokeAt = Date()
            self.openInput(mic: true, focus: false)
        }
        model.onUndo = { [weak self] in
            guard let self else { return }
            self.model.answer = LocalBrain.performUndo(self.model)
        }
    }

    /// Whisper when it's installed and chosen (Uzbek, offline); Apple's recognizer otherwise.
    private func selectVoiceEngine() {
        speech.stop(commit: false)
        whisper.configure(language: config.whisperLanguage, model: config.whisperModel)
        usingWhisper = config.speechEngine == "whisper" && WhisperServer.isInstalled(model: config.whisperModel)
        if config.speechEngine == "whisper" && !usingWhisper {
            olog("whisper chosen but not installed; using Apple speech")
        }
        speech = usingWhisper ? WhisperInput(server: whisper) : SpeechInput()
        if !usingWhisper { whisper.stop() }
        model.engines = [("tanish", usingWhisper ? "whisper \(config.whisperLanguage)" : "apple"),
                         ("ovoz", config.speak == "off" ? "oʻchiq" : (UzbekVoice.isInstalled ? "mms uz" : "tizim"))]
        wireSpeech()
    }

    private func wireSpeech() {
        speech.onBusy = { [weak self] on in self?.model.transcribing = on }
        speech.onPartial = { [weak self] t in self?.model.inputText = t }
        speech.onLevel = { [weak self] l in
            Levels.shared.mic = Double(l)
            if abs((self?.model.micLevel ?? 0) - l) > 0.08 || l == 0 { self?.model.micLevel = l }
        }
        speech.onNote = { [weak self] n in self?.model.micNote = n }
        speech.onState = { [weak self] on in
            guard let self else { return }
            self.model.micOn = on
            if on { self.wake.suspend() } else if !self.model.speaking { self.wake.resume(after: 1.2) }
        }
        speech.onFinal = { [weak self] t in
            guard let self, self.model.phase == .input || self.model.phase == .done else { return }
            self.assistant.submit(t, byVoice: true)
        }
    }

    private func startMic() {
        model.micNote = ""
        voiceRequest = true
        speech.start(locale: config.speechLocale, offline: !model.online)
    }

    // MARK: "Hey Claude"

    private func setupWake() {
        model.wakeAvailable = WakeListener.isInstalled
        wake.onState = { [weak self] on in self?.model.wakeListening = on }
        wake.onWake = { [weak self] in self?.woke() }
        if config.wakeWord && model.wakeAvailable && model.wakePausedUntil == nil {
            wake.start(threshold: config.wakeThreshold)
            if usingWhisper { whisper.ensure { _ in } }       // the first "Hey Claude" shouldn't wait for the model
            if config.speak != "off" && UzbekVoice.isInstalled { speaker.uzbek.warm() }
        } else {
            wake.stop()
        }
    }

    private func woke() {
        guard model.approvals.isEmpty, !model.micOn else { return }
        if model.phase == .thinking || model.phase == .answering || model.speaking {
            assistant.cancel()                       // barge in: a new request replaces the old one
        }
        speaker.stop()
        model.phase = .idle
        wake.suspend()                               // free the microphone before Whisper opens it
        if config.sounds { NSSound(named: "Tink")?.play() }
        Levels.shared.wokeAt = Date()
        olog("woke: opening the mic")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.openInput(mic: true, focus: false)
            self.model.wokeByVoice = true
        }
    }

    /// nil resumes; otherwise pause for that many seconds.
    private func pauseWake(_ seconds: TimeInterval?) {
        wakePauseWork?.cancel()
        guard let seconds else {
            model.wakePausedUntil = nil
            setupWake()
            return
        }
        model.wakePausedUntil = Date().addingTimeInterval(seconds)
        wake.stop()
        let w = DispatchWorkItem { [weak self] in
            self?.model.wakePausedUntil = nil
            self?.setupWake()
        }
        wakePauseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func openInput(mic: Bool, focus: Bool = true) {
        guard model.approvals.isEmpty else { return }
        model.wokeByVoice = false
        if model.phase == .idle {
            model.question = ""
            model.answer = ""
            model.status = ""
            model.inputText = ""
            model.micNote = ""
            model.phase = .input
        }
        if focus {
            window.takeKey()
            model.focusToken += 1
        }
        assistant.prewarm()
        if usingWhisper { whisper.ensure { _ in } }      // load the model while you start talking
        if mic && config.speak != "off" && UzbekVoice.isInstalled { speaker.uzbek.warm() }
        if mic && !model.micOn { startMic() }
    }

    private func dismiss(_ why: String = "") {
        if !why.isEmpty || model.phase != .idle { olog("dismiss \(why) (phase \(model.phase))") }
        speech.stop(commit: false)
        voiceRequest = false
        assistant.cancel()
        model.phase = .idle
        model.inputText = ""
        model.micNote = ""
        model.status = ""
        model.card = nil
        window.releaseKey()
        window.resetHover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.assistant.drainQueue() }
    }

    private func hotkeyPressed() {
        if model.phase == .idle { openInput(mic: config.micOnHotkey) } else { dismiss() }
    }

    private func registerHotkey() {
        if let label = hotkey.register(config.hotkey, action: { [weak self] in self?.hotkeyPressed() }) {
            model.hotkeyLabel = label
        } else {
            model.hotkeyLabel = "—"
            olog("hotkey \(config.hotkey) could not be registered (another app may own it)")
        }
    }

    /// An answer stays until you move on: it collapses a while after the pointer left.
    private func lingerTick() {
        window.recheckPointer()
        guard model.phase == .done, model.approvals.isEmpty else { return }
        guard !window.isPointerInside, !model.speaking, !model.micOn,
              model.inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let words = Double(model.answer.split(separator: " ").count)
        let hold = min(40, 9 + words * 0.35)
        if Date().timeIntervalSince(max(assistant.doneAt, window.lastInside)) > hold { dismiss() }
    }

    // MARK: debug (only with OROL_DEBUG set): SIGUSR1 = snapshot, SIGUSR2 = run debug/command.json

    private var debugSources: [DispatchSourceSignal] = []

    private var debugDir: URL {
        let u = Paths.support.appendingPathComponent("debug")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func installDebugSignals() {
        for (sig, action) in [(SIGUSR1, { [weak self] in self?.debugSnapshot() } as () -> Void),
                              (SIGUSR2, { [weak self] in self?.debugCommand() } as () -> Void)] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler(handler: action)
            src.resume()
            debugSources.append(src)
        }
        olog("debug signals installed")
    }

    private func debugSnapshot() {
        let state: [String: Any] = [
            "layout": "\(model.layout)", "phase": "\(model.phase)", "question": model.question,
            "answer": model.answer, "status": model.status, "input": model.inputText,
            "micOn": model.micOn, "micNote": model.micNote, "hovering": model.hovering,
            "pill": [model.pillSize.width, model.pillSize.height],
            "notch": [model.notch.width, model.notch.height], "hasNotch": model.hasNotch,
            "hooksInstalled": model.hooksInstalled, "hotkey": model.hotkeyLabel,
            "isKey": window.panel.isKeyWindow, "ignoresMouse": window.panel.ignoresMouseEvents,
            "frame": NSStringFromRect(window.panel.frame), "visible": window.panel.isVisible,
            "sessions": model.sessions.map { ["id": $0.id, "project": $0.project, "status": "\($0.status)",
                                              "ticker": $0.ticker, "prompt": $0.prompt, "summary": $0.summary,
                                              "plus": $0.plus, "minus": $0.minus, "isTask": $0.isTask] },
            "approvals": model.approvals.map { ["tool": $0.tool, "title": $0.title, "detail": $0.detail,
                                                "dangerous": $0.dangerous, "canAlways": $0.canAlways,
                                                "questions": $0.questions.count, "fromOrol": $0.fromOrol] },
            "media": model.media.map { ["title": $0.title, "artist": $0.artist, "playing": $0.playing] } as Any,
            "timers": model.timers.map { $0.end.timeIntervalSinceNow },
            "flash": model.flash.map { [$0.left, $0.right] } as Any,
            "battery": [model.battery.percent, model.battery.plugged],
            "claude": "\(model.claude)", "online": model.online,
            "wakeListening": model.wakeListening, "wokeByVoice": model.wokeByVoice, "transcribing": model.transcribing,
            "card": model.card.map { "\($0)".prefix(120).description } ?? "",
            "usage": [model.usage5h ?? -1, model.usage7d ?? -1],
            "queue": model.queue.map { ["q": $0.question, "a": $0.answer ?? "-"] },
        ]
        if let d = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: debugDir.appendingPathComponent("state.json"))
        }
        Shots.render(model: model, to: debugDir.appendingPathComponent("snapshot.png"))
    }

    private func debugCommand() {
        guard let d = try? Data(contentsOf: debugDir.appendingPathComponent("command.json")),
              let c = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if let t = c["ask"] as? String { openInput(mic: false); model.onSubmit(t, false) }
        if c["open"] != nil { openInput(mic: c["open"] as? Bool ?? false) }
        if c["dismiss"] != nil { dismiss() }
        if let k = c["decide"] as? String, let card = model.approvals.first {
            hub.decide(card, kind: k, answers: c["answers"] as? [String: String] ?? [:])
        }
        if let h = c["hover"] as? Bool { model.hovering = h }
        if let off = c["forceOffline"] as? Bool { assistant.forceOffline = off }
        if c["drain"] != nil { assistant.drainQueue() }
        if c["wake"] != nil { woke() }
        if let b = c["axdump"] as? String {
            let text = AXMedia.dump(bundleId: b)
            try? text.write(to: debugDir.appendingPathComponent("ax.txt"), atomically: true, encoding: .utf8)
        }
        if let path = c["simulateMic"] as? String, let w = speech as? WhisperInput,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 44 {
            openInput(mic: false)
            voiceRequest = true
            let pcm = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            w.simulate(pcm.map { Float($0) / 32768 })
        }
        if let r = c["rate"] as? [String: Any] { assistant.noteRate(["type": "rate_limit_event", "rate_limit_info": r]) }
    }

    // MARK: status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "capsule.portrait.tophalf.filled", accessibilityDescription: "Orol")
                ?? NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Orol")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector, state: Bool? = nil, key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            if let state { i.state = state ? .on : .off }
            menu.addItem(i)
        }
        model.hooksInstalled = HookInstaller.isInstalled()
        add("Soʻrash yoki yozish  (\(model.hotkeyLabel))", #selector(menuAsk))
        add("Gapirish", #selector(menuTalk))
        menu.addItem(.separator())
        add("Claude Code sessiyalarini kuzatish", #selector(menuHooks), state: model.hooksInstalled)
        let voice = NSMenuItem(title: "Ovozni tanish", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let whisperOK = WhisperServer.binary != nil && WhisperServer.model(named: config.whisperModel) != nil
        for (title, engine, lang) in [("Whisper · oʻzbekcha", "whisper", "uz"), ("Whisper · ruscha", "whisper", "ru"),
                                      ("Whisper · inglizcha", "whisper", "en"), ("Whisper · tilni oʻzi aniqlasin", "whisper", "auto"),
                                      ("Apple · English", "apple", "en-US"), ("Apple · Русский", "apple", "ru-RU")] {
            let i = NSMenuItem(title: title + (engine == "whisper" && !whisperOK ? " (oʻrnatilmagan)" : ""),
                               action: #selector(menuVoice(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = [engine, lang]
            i.isEnabled = engine == "apple" || whisperOK
            let on = engine == "whisper" ? (usingWhisper && config.whisperLanguage == lang)
                                         : (!usingWhisper && config.speechLocale == lang)
            i.state = on ? .on : .off
            sub.addItem(i)
        }
        voice.submenu = sub
        menu.addItem(voice)
        add("Javobni ovoz chiqarib oʻqish", #selector(menuSpeak), state: config.speak != "off")
        add("Tovushlar", #selector(menuSounds), state: config.sounds)
        if model.wakeAvailable {
            add("“Hey Claude” bilan uygʻotish", #selector(menuWake), state: config.wakeWord)
            if config.wakeWord {
                if model.wakePausedUntil != nil { add("Tinglashni davom ettirish", #selector(menuWakeResume)) }
                else { add("Tinglashni 1 soatga toʻxtatish", #selector(menuWakePause)) }
            }
        }
        add("Tizimga kirganda ishga tushirish", #selector(menuLogin), state: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("Sozlamalar faylini ochish", #selector(menuConfig))
        add("Sozlamalarni qayta yuklash", #selector(menuReload))
        add("Jurnalni ochish", #selector(menuLog))
        menu.addItem(.separator())
        add("Orol’dan chiqish", #selector(menuQuit), key: "q")
    }

    @objc private func menuAsk() { openInput(mic: false) }
    @objc private func menuTalk() { openInput(mic: true) }
    @objc private func menuHooks() { toggleHooks() }
    @objc private func menuSpeak() {
        config.speak = (config.speak == "off") ? "voice" : "off"
        config.save()
        assistant.reload(config)
    }
    @objc private func menuVoice(_ item: NSMenuItem) {
        guard let pair = item.representedObject as? [String] else { return }
        config.speechEngine = pair[0]
        if pair[0] == "whisper" { config.whisperLanguage = pair[1] } else { config.speechLocale = pair[1] }
        config.save()
        selectVoiceEngine()
    }
    @objc private func menuWake() {
        config.wakeWord.toggle()
        config.save()
        model.wakePausedUntil = nil
        setupWake()
    }
    @objc private func menuWakePause() { pauseWake(3600) }
    @objc private func menuWakeResume() { pauseWake(nil) }
    @objc private func menuSounds() { config.sounds.toggle(); config.save() }
    @objc private func menuLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Avtomatik ishga tushirishni oʻzgartirib boʻlmadi", error.localizedDescription)
        }
    }
    @objc private func menuConfig() {
        if !FileManager.default.fileExists(atPath: Paths.config.path) { config.save() }
        NSWorkspace.shared.open(Paths.config)
    }
    @objc private func menuReload() {
        config = OrolConfig.load()
        assistant.reload(config)
        registerHotkey()
        selectVoiceEngine()
        setupWake()
    }
    @objc private func menuLog() { NSWorkspace.shared.open(Paths.log) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: hooks

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// Nothing is written to the user's Claude Code settings until they confirm here.
    private func toggleHooks() {
        let installed = HookInstaller.isInstalled()
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        if installed {
            a.messageText = "Sessiyalarni kuzatishni oʻchirasizmi?"
            a.informativeText = "Orol qoʻshgan hook yozuvlari \(HookInstaller.settingsURL.path) faylidan olib tashlanadi. Boshqa hooklaringizga tegilmaydi."
            a.addButton(withTitle: "Oʻchirish")
        } else {
            a.messageText = "Claude Code sessiyalarini kuzatish yoqilsinmi?"
            a.informativeText = """
            Orol \(HookInstaller.settingsURL.path) fayliga oʻz hooklarini qoʻshadi (\(HookInstaller.events.map { $0.0 }.joined(separator: ", "))). \
            Mavjud hooklaringiz oʻz joyida qoladi va avval faylning zaxira nusxasi olinadi.

            Shundan keyin har bir Claude Code sessiyasi orolda koʻrinadi, ruxsat soʻrovlariga esa oroldan javob bera olasiz. \
            Orol ishlamayotgan boʻlsa, hook hech narsa qilmaydi. Yangi hooklar keyingi ochilgan sessiyalardan boshlab ishlaydi.
            """
            a.addButton(withTitle: "Yoqish")
        }
        a.addButton(withTitle: "Bekor qilish")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            if installed { try HookInstaller.uninstall() } else { try HookInstaller.install() }
        } catch {
            alert("Hooklarni oʻzgartirib boʻlmadi", error.localizedDescription)
        }
        model.hooksInstalled = HookInstaller.isInstalled()
    }
}
