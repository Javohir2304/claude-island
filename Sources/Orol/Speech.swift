import AVFoundation
import NaturalLanguage
import Speech

/// Microphone -> text with Apple's speech recognizer. Ends the request by itself
/// after a pause, like hey-claude's end-of-turn detection.
final class SpeechInput: VoiceInput {
    var onBusy: (Bool) -> Void = { _ in }
    var onPartial: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    var onLevel: (CGFloat) -> Void = { _ in }
    var onNote: (String) -> Void = { _ in }
    var onState: (Bool) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: DispatchWorkItem?
    private var text = ""
    private(set) var running = false
    private var session = 0

    static let pauseAfterSpeech: TimeInterval = 1.5
    static let startTimeout: TimeInterval = 7

    static var canAskPermission: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
            && Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    func start(locale: String, offline: Bool = false) {
        guard !running else { return }
        guard Self.canAskPermission else {
            onNote("Mikrofon faqat Orol.app orqali ishlaydi")
            return
        }
        session += 1
        let mine = session
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    guard mine == self.session else { return }
                    guard status == .authorized else {
                        self.onNote("Nutqni tanishga ruxsat berilmagan (System Settings → Privacy → Speech Recognition)")
                        return
                    }
                    guard granted else {
                        self.onNote("Mikrofonga ruxsat berilmagan (System Settings → Privacy → Microphone)")
                        return
                    }
                    self.begin(locale: locale, offline: offline)
                }
            }
        }
    }

    private func begin(locale: String, offline: Bool) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            onNote("“\(locale)” tili uchun nutqni tanish mavjud emas")
            return
        }
        if offline && !recognizer.supportsOnDeviceRecognition {
            onNote("Internet yoʻq: \(locale) tilini tanish uchun internet kerak. en-US qurilmaning oʻzida ishlaydi — yozib ham soʻrashingiz mumkin.")
            return
        }
        guard recognizer.isAvailable else {
            onNote("Nutqni tanish hozir mavjud emas (internetni tekshiring)")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        text = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onNote("Mikrofon topilmadi")
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(n))
            let level = CGFloat(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40)))
            DispatchQueue.main.async { self?.onLevel(level) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onNote("Mikrofonni ochib boʻlmadi: \(error.localizedDescription)")
            return
        }
        running = true
        onState(true)
        onNote("")
        let mine = session
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.running, mine == self.session else { return }
                if let result {
                    let t = result.bestTranscription.formattedString
                    if t != self.text {
                        self.text = t
                        self.onPartial(t)
                        self.armSilence(Self.pauseAfterSpeech)
                    }
                    if result.isFinal { self.stop(commit: true) }
                } else if error != nil {
                    self.stop(commit: !self.text.isEmpty)
                }
            }
        }
        armSilence(Self.startTimeout)
    }

    private func armSilence(_ seconds: TimeInterval) {
        silence?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.stop(commit: !self.text.isEmpty)
        }
        silence = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// commit: hand the text over as a finished request.
    func stop(commit: Bool) {
        session += 1
        silence?.cancel()
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        onLevel(0)
        onState(false)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        if commit, !t.isEmpty { onFinal(t) }
    }
}

/// Uzbek voice: Meta's MMS-TTS through a small onnxruntime helper (offline). Sentences
/// are synthesized in order and played back to back.
final class UzbekVoice: NSObject, AVAudioPlayerDelegate {
    static var dir: URL { Paths.support.appendingPathComponent("tts") }
    static var python: URL { Paths.support.appendingPathComponent("wake-venv/bin/python") }
    static var script: URL? {
        if let u = Bundle.main.url(forResource: "orol_tts", withExtension: "py") { return u }
        let u = dir.appendingPathComponent("orol_tts.py")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.onnx").path) && script != nil
    }

    var onState: (Bool) -> Void = { _ in }
    private var process: Process?
    private var input: FileHandle?
    private var nextId = 1
    private var order: [Int] = []
    private var files: [Int: URL] = [:]
    private var player: AVAudioPlayer?
    private(set) var active = false

    func warm() { ensure() }

    private func ensure() {
        guard process?.isRunning != true, let script = Self.script else { return }
        let p = Process()
        p.executableURL = Self.python
        p.arguments = ["-I", script.path, Self.dir.path]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        var buffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer[buffer.startIndex..<nl], encoding: .utf8) ?? ""
                buffer = Data(buffer[buffer.index(after: nl)...])
                DispatchQueue.main.async { self?.line(line) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.process = nil
                self.input = nil
            }
        }
        do {
            try p.run()
            process = p
            input = inPipe.fileHandleForWriting
        } catch {
            olog("uzbek voice failed to start: \(error)")
        }
    }

    func say(_ sentence: String) {
        let t = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        ensure()
        guard let input, let data = try? JSONSerialization.data(withJSONObject: ["id": nextId, "text": t]) else { return }
        order.append(nextId)
        nextId += 1
        if !active { active = true; onState(true) }
        try? input.write(contentsOf: data + Data([0x0A]))
    }

    private func line(_ s: String) {
        let parts = s.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let id = Int(parts[1]), order.contains(id) else { return }
        if parts[0] == "OK", parts.count == 3 { files[id] = URL(fileURLWithPath: parts[2]) }
        else { order.removeAll { $0 == id } }
        pump()
    }

    private func pump() {
        guard player?.isPlaying != true else { return }
        guard let id = order.first else { finishIfIdle(); return }
        guard let url = files[id] else { return }               // still being made
        order.removeFirst()
        files[id] = nil
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.isMeteringEnabled = true
            player = p
            p.play()
            // the island's thread follows the voice's loudness
            Levels.shared.voiceMeter = { [weak p] in
                guard let p, p.isPlaying else { return 0 }
                p.updateMeters()
                return Double(min(1, max(0, (p.averagePower(forChannel: 0) + 42) / 36)))
            }
        } catch {
            pump()
        }
        try? FileManager.default.removeItem(at: url)
    }

    private func finishIfIdle() {
        if order.isEmpty && player?.isPlaying != true { Levels.shared.voiceMeter = nil }
        if active && order.isEmpty && player?.isPlaying != true { active = false; onState(false) }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.pump() }
    }

    func stop() {
        order.removeAll()
        for (_, u) in files { try? FileManager.default.removeItem(at: u) }
        files.removeAll()
        player?.stop()
        player = nil
        Levels.shared.voiceMeter = nil
        if active { active = false; onState(false) }
    }

    func shutdown() {
        stop()
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }
}

/// Reads answers aloud, sentence by sentence while they stream: Uzbek with the MMS voice,
/// English and Russian with the system voices.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private enum Mode { case none, uzbek, system(AVSpeechSynthesisVoice) }
    private let synth = AVSpeechSynthesizer()
    let uzbek = UzbekVoice()
    private var spoken = 0              // characters of the answer already queued
    private var mode: Mode = .none
    private var decided = false
    private var pendingCount = 0
    var onState: (Bool) -> Void = { _ in }

    override init() {
        super.init()
        synth.delegate = self
        uzbek.onState = { [weak self] on in
            guard let self else { return }
            self.onState(on || self.synth.isSpeaking)
        }
    }

    /// Uzbek in Latin script: its letters and very common words give it away.
    static func looksUzbek(_ text: String) -> Bool {
        let t = LocalBrain.normalize(text)
        if t.contains("o'") || t.contains("g'") { return true }
        let words = Set(t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init))
        let common: Set<String> = ["va", "bu", "men", "siz", "uchun", "bilan", "emas", "bor", "yo'q", "hozir", "qilib",
                                   "kerak", "mumkin", "bo'ladi", "yoki", "lekin", "ham", "deb", "esa", "qanday", "nima",
                                   "sizning", "mening", "bugun", "ertaga", "soat", "taxminan", "ko'ra", "haqida"]
        let hits = words.intersection(common).count
        let suffixes = t.split(separator: " ").filter { $0.hasSuffix("ning") || $0.hasSuffix("lar") || $0.hasSuffix("dagi") || $0.hasSuffix("ga") }.count
        return hits >= 2 || (hits >= 1 && suffixes >= 2)
    }

    private func pick(for text: String) -> Mode {
        if UzbekVoice.isInstalled && Self.looksUzbek(text) { return .uzbek }
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p > 0.75,
              ["en", "ru"].contains(lang.rawValue),
              let v = AVSpeechSynthesisVoice(language: lang.rawValue == "en" ? "en-US" : "ru-RU") else { return .none }
        return .system(v)
    }

    private func enqueue(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        switch mode {
        case .none: return
        case .uzbek: uzbek.say(t)
        case .system(let voice):
            let u = AVSpeechUtterance(string: t)
            u.voice = voice
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
            pendingCount += 1
            synth.speak(u)
            onState(true)
        }
    }

    private var silent: Bool { if case .none = mode { return true } else { return false } }

    /// Called with the whole answer so far.
    func feed(_ full: String) {
        if !decided {
            guard full.count >= 24 else { return }
            decided = true
            mode = pick(for: full)
        }
        guard !silent, full.count > spoken else { return }
        let rest = full[full.index(full.startIndex, offsetBy: spoken)...]
        guard let last = rest.lastIndex(where: { ".!?\n".contains($0) }) else { return }
        let end = rest.index(after: last)
        enqueue(String(rest[..<end]))
        spoken = full.distance(from: full.startIndex, to: end)
    }

    func finish(_ full: String) {
        if !decided {
            decided = true
            mode = pick(for: full)
        }
        if !silent, full.count > spoken {
            enqueue(String(full[full.index(full.startIndex, offsetBy: spoken)...]))
        }
        spoken = 0
        decided = false
        mode = .none
    }

    func stop() {
        spoken = 0
        decided = false
        mode = .none
        pendingCount = 0
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        uzbek.stop()
        onState(false)
    }

    private func ended() {
        pendingCount = max(0, pendingCount - 1)
        if pendingCount == 0 { DispatchQueue.main.async { self.onState(self.uzbek.active) } }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance u: AVSpeechUtterance) {
        DispatchQueue.main.async { Levels.shared.voicePulse = Date() }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { ended() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { ended() }
}
