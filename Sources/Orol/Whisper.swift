import AVFoundation
import Darwin
import Foundation

/// What the island needs from any speech-to-text engine.
protocol VoiceInput: AnyObject {
    var onPartial: (String) -> Void { get set }
    var onFinal: (String) -> Void { get set }
    var onLevel: (CGFloat) -> Void { get set }
    var onNote: (String) -> Void { get set }
    var onState: (Bool) -> Void { get set }
    var onBusy: (Bool) -> Void { get set }
    var running: Bool { get }
    func start(locale: String, offline: Bool)
    func stop(commit: Bool)
}

// MARK: - The local whisper.cpp server

/// One warm `whisper-server` (whisper.cpp, Metal) on 127.0.0.1. Started when the mic is
/// about to be used, stopped after a while without use, so the model isn't held in memory all day.
final class WhisperServer {
    static let binaries = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
    static var modelsDir: URL { Paths.support.appendingPathComponent("models") }
    /// Best first. Uzbek: the Uzbek fine-tune (navai-uz/whisper-medium-uzbek) is far better than
    /// any stock model. Other languages: stock large-v3 (the fine-tune has forgotten them).
    static let uzbekModels = ["ggml-uz-medium-q8_0.bin", "ggml-uz-medium.bin"]
    static let generalModels = ["ggml-large-v3-turbo-q8_0.bin", "ggml-large-v3-q5_0.bin", "ggml-large-v3-turbo.bin",
                                "ggml-large-v3.bin", "ggml-medium.bin", "ggml-small.bin"]
    static var language = "uz"
    static var preferredModels: [String] { language == "uz" ? uzbekModels + generalModels : generalModels + uzbekModels }

    static var binary: String? { binaries.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func model(named name: String) -> URL? {
        if !name.isEmpty {
            let u = name.hasPrefix("/") || name.hasPrefix("~")
                ? URL(fileURLWithPath: Paths.expand(name)) : modelsDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return preferredModels.map { modelsDir.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isInstalled(model: String) -> Bool { binary != nil && self.model(named: model) != nil }

    private var process: Process?
    private var port = 0
    private static var pidFile: URL { Paths.support.appendingPathComponent("whisper-server.pid") }

    /// A whisper-server left behind by an Orol that was killed (it holds ~1 GB): stop it.
    static func reapOrphan() {
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return }
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, String(cString: buf).hasSuffix("whisper-server") {
            kill(pid, SIGTERM)
            olog("stopped a leftover whisper-server (\(pid))")
        }
        try? FileManager.default.removeItem(at: pidFile)
    }
    private(set) var ready = false
    private var waiting: [(Bool) -> Void] = []
    private var idleStop: DispatchWorkItem?
    private var language = "uz"
    private var modelName = ""
    static let idleSeconds: TimeInterval = 15 * 60

    func configure(language: String, model: String) {
        Self.language = language
        let changed = language != self.language || model != modelName
        self.language = language
        self.modelName = model
        if changed { stop() }
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 18765 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : 18765
    }

    /// Calls back (main queue) once the server answers, or with false if it can't start.
    func ensure(_ done: @escaping (Bool) -> Void) {
        touch()
        if ready, process?.isRunning == true { done(true); return }
        waiting.append(done)
        guard process == nil else { return }
        guard let bin = Self.binary, let model = Self.model(named: modelName) else { finishWaiting(false); return }
        port = Self.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        // No initial prompt: on short requests Whisper tends to repeat the prompt instead of listening.
        p.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "-l", language,
                       "-t", "6", "-nt", "-sns", "-bs", "5"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.currentDirectoryURL = Paths.support
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                olog("whisper-server exited (\(proc.terminationStatus))")
                self.process = nil
                self.ready = false
                self.finishWaiting(false)
            }
        }
        do {
            try p.run()
            process = p
            try? String(p.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)
            olog("whisper-server starting: \(model.lastPathComponent), language \(language), port \(port)")
            poll(deadline: Date().addingTimeInterval(60))
        } catch {
            olog("whisper-server failed to start: \(error)")
            finishWaiting(false)
        }
    }

    private func poll(deadline: Date) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            DispatchQueue.main.async {
                guard let self, self.process != nil else { return }
                if (resp as? HTTPURLResponse) != nil {
                    self.ready = true
                    olog("whisper-server ready")
                    self.finishWaiting(true)
                } else if Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.poll(deadline: deadline) }
                } else {
                    olog("whisper-server did not come up in time")
                    self.stop()
                    self.finishWaiting(false)
                }
            }
        }.resume()
    }

    private func finishWaiting(_ ok: Bool) {
        let w = waiting
        waiting = []
        w.forEach { $0(ok) }
    }

    private func touch() {
        idleStop?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.stop() }
        idleStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleSeconds, execute: w)
    }

    func stop() {
        idleStop?.cancel()
        ready = false
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    /// 16 kHz mono samples -> text (main queue). nil on failure.
    func transcribe(_ samples: [Float], completion: @escaping (String?) -> Void) {
        touch()
        guard ready, let url = URL(string: "http://127.0.0.1:\(port)/inference") else { completion(nil); return }
        let boundary = "orol-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "json")
        field("temperature", "0.0")
        field("temperature_inc", "0.2")
        field("language", language)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"orol.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(Self.wav(samples))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { data, _, err in
            var text: String?
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                text = obj["text"] as? String
            } else if let err {
                olog("whisper request failed: \(err.localizedDescription)")
            }
            DispatchQueue.main.async { completion(text.map(Self.clean)) }
        }.resume()
    }

    /// Whisper's habits on near-silence and its formatting quirks.
    static func clean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"[\[\(][^\]\)]{0,40}[\]\)]"#, with: "", options: .regularExpression)   // [Musiqa], (kulgi)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let junk = ["субтитры", "продолжение следует", "thank you for watching", "thanks for watching", "redaktor",
                    "subtitles by", "amara.org", "obuna bo'ling", "obuna boʻling", "kanalimizga obuna", "dimatorzok",
                    "корректор", "редактор субтитров"]
        let low = t.lowercased()
        if junk.contains(where: low.contains) { return "" }
        // Uzbek apostrophes, the way the rest of Orol writes them
        t = t.replacingOccurrences(of: "o'", with: "oʻ").replacingOccurrences(of: "g'", with: "gʻ")
            .replacingOccurrences(of: "O'", with: "Oʻ").replacingOccurrences(of: "G'", with: "Gʻ")
            .replacingOccurrences(of: "o‘", with: "oʻ").replacingOccurrences(of: "g‘", with: "gʻ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t
    }

    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        let rate: UInt32 = 16000
        let bytes = UInt32(samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}

// MARK: - Microphone -> whisper

/// Records 16 kHz mono, finds where you start and stop talking from the level (an
/// adaptive noise floor), shows a live draft while you talk and sends the whole
/// utterance to whisper when you stop.
final class WhisperInput: VoiceInput {
    var onPartial: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    var onLevel: (CGFloat) -> Void = { _ in }
    var onNote: (String) -> Void = { _ in }
    var onState: (Bool) -> Void = { _ in }
    var onBusy: (Bool) -> Void = { _ in }

    let server: WhisperServer
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var running = false
    private var session = 0

    // end-of-turn detection (main queue)
    private var floorDb: Float = -60
    private var speechStartIndex: Int?
    private var loudFrames = 0
    private var lastLoud = Date()
    private var started = Date()
    private var partialInFlight = false
    private var lastPartialAt = Date.distantPast
    private var lastPartialCount = 0

    static let silenceToEnd: TimeInterval = 1.1
    static let startTimeout: TimeInterval = 8
    static let maxSeconds: Double = 60

    init(server: WhisperServer) { self.server = server }

    func start(locale: String, offline: Bool) {
        guard !running else { return }
        guard SpeechInput.canAskPermission else { onNote("Mikrofon faqat Orol.app orqali ishlaydi"); return }
        session += 1
        let mine = session
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard mine == self.session else { return }
                guard granted else {
                    self.onNote("Mikrofonga ruxsat berilmagan (System Settings → Privacy → Microphone)")
                    return
                }
                self.begin()
            }
        }
    }

    private func begin() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { onNote("Mikrofon topilmadi"); return }
        converter = AVAudioConverter(from: format, to: target)
        lock.lock(); samples = []; lock.unlock()
        floorDb = -60
        speechStartIndex = nil
        loudFrames = 0
        partialInFlight = false
        lastPartialCount = 0
        started = Date()
        lastLoud = Date()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onNote("Mikrofonni ochib boʻlmadi: \(error.localizedDescription)")
            olog("whisper mic failed: \(error)")
            return
        }
        running = true
        onState(true)
        onNote(server.ready ? "" : "Whisper yuklanmoqda…")
        let mine = session
        server.ensure { [weak self] ok in
            guard let self, mine == self.session else { return }
            if ok { self.onNote("") }
            else {
                self.onNote("Whisper ishga tushmadi. Menyu → “Ovozni tanish”dan Apple’ni tanlang yoki jurnalni koʻring.")
                self.stop(commit: false)
            }
        }
    }

    /// Audio thread: convert to 16 kHz mono and keep it; measure the level.
    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        let count = samples.count
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.frame(db: db, count: count) }
    }

    /// Main queue, ~8 times a second.
    private func frame(db: Float, count: Int) {
        guard running else { return }
        onLevel(CGFloat(min(1, max(0, (db + 50) / 40))))
        let now = Date()
        // The floor follows quiet stretches quickly and loud ones slowly.
        floorDb = db < floorDb ? floorDb * 0.7 + db * 0.3 : floorDb * 0.995 + db * 0.005
        let threshold = max(floorDb + 10, -52)
        if db > threshold {
            loudFrames += 1
            lastLoud = now
            if speechStartIndex == nil && loudFrames >= 2 { speechStartIndex = max(0, count - 16000 / 2) }
        } else {
            loudFrames = 0
        }

        if speechStartIndex == nil {
            if now.timeIntervalSince(started) > Self.startTimeout { stop(commit: false) }
            return
        }
        if now.timeIntervalSince(lastLoud) > Self.silenceToEnd || Double(count) / 16000 > Self.maxSeconds {
            stop(commit: true)
            return
        }
        // A live draft while talking.
        if server.ready, !partialInFlight, now.timeIntervalSince(lastPartialAt) > 1.2, count - lastPartialCount > 16000 {
            partialInFlight = true
            lastPartialAt = now
            lastPartialCount = count
            let mine = session
            server.transcribe(utterance()) { [weak self] text in
                guard let self else { return }
                self.partialInFlight = false
                guard self.running, mine == self.session, let text, !text.isEmpty else { return }
                self.onPartial(text)
            }
        }
    }

    /// Debug: play 16 kHz mono samples through the same path as the microphone, in real time.
    func simulate(_ audio: [Float]) {
        guard !running else { return }
        session += 1
        lock.lock(); samples = []; lock.unlock()
        floorDb = -60; speechStartIndex = nil; loudFrames = 0; partialInFlight = false; lastPartialCount = 0
        started = Date(); lastLoud = Date()
        running = true
        onState(true)
        server.ensure { _ in }
        let block = 2048
        var offset = 0
        let mine = session
        func step() {
            guard self.running, mine == self.session else { return }
            let end = min(offset + block, audio.count)
            let chunk = offset < end ? Array(audio[offset..<end]) : [Float](repeating: 0, count: block)
            offset = end
            var sum: Float = 0
            for x in chunk { sum += x * x }
            let db = 20 * log10(max(sqrt(sum / Float(chunk.count)), 1e-6))
            self.lock.lock(); self.samples.append(contentsOf: chunk); let count = self.samples.count; self.lock.unlock()
            self.frame(db: db, count: count)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(block) / 16000) { step() }
        }
        step()
    }

    private func utterance() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let from = min(speechStartIndex ?? 0, samples.count)
        return Array(samples[from...])
    }

    func stop(commit: Bool) {
        session += 1
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onLevel(0)
        onState(false)
        let heard = speechStartIndex != nil
        onNote("")
        let audio = utterance() + [Float](repeating: 0, count: 3200)      // a little tail helps the last word
        guard commit, heard, audio.count > 16000 / 3 else { return }
        onBusy(true)
        let finish: ([Float]) -> Void = { [weak self] a in
            self?.server.transcribe(a) { text in
                guard let self else { return }
                self.onBusy(false)
                guard let text, !text.isEmpty else {
                    self.onNote("Gapingizni tushunolmadim, qayta urinib koʻring.")
                    return
                }
                self.onPartial(text)
                self.onFinal(text)
            }
        }
        if server.ready { finish(audio) }
        else {
            server.ensure { [weak self] ok in
                if ok { finish(audio) } else { self?.onBusy(false); self?.onNote("Whisper ishga tushmadi.") }
            }
        }
    }
}
