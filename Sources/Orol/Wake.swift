import AVFoundation
import Foundation

/// "Hey Claude": Orol listens to the microphone and feeds 16 kHz audio to a small
/// openWakeWord helper (hey-claude's shared model). Nothing is recorded or sent anywhere;
/// the helper only answers "WAKE". While Orol itself records a request the listener
/// steps aside, so only one thing uses the microphone at a time.
final class WakeListener {
    var onWake: () -> Void = {}
    var onState: (Bool) -> Void = { _ in }

    static var dir: URL { Paths.support.appendingPathComponent("wake") }
    static var python: URL { Paths.support.appendingPathComponent("wake-venv/bin/python") }
    static var model: URL { dir.appendingPathComponent("hey_claude.onnx") }
    static var script: URL? {
        if let u = Bundle.main.url(forResource: "orol_wake", withExtension: "py") { return u }
        let u = dir.appendingPathComponent("orol_wake.py")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: model.path) && script != nil
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var process: Process?
    private var input: FileHandle?
    private let writeQueue = DispatchQueue(label: "orol.wake.write")
    private var threshold = 0.5
    private(set) var listening = false
    private var wanted = false          // the user wants it on
    private var suspended = false       // Orol is using the mic itself
    private var restartWork: DispatchWorkItem?
    private var failures = 0

    func start(threshold: Double) {
        self.threshold = threshold
        wanted = true
        apply()
    }

    func stop() {
        wanted = false
        apply()
    }

    /// Orol records a request (or speaks): step aside.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        apply()
    }

    /// Back to listening after `delay` seconds (a short cooldown so the end of a request
    /// or of a spoken answer doesn't wake it again).
    func resume(after delay: TimeInterval = 0.8) {
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.suspended = false
            self.apply()
        }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func apply() {
        let should = wanted && !suspended && Self.isInstalled
        if should { ensureHelper(); startAudio() } else { stopAudio() }
        if !wanted { stopHelper() }
    }

    // MARK: helper process

    private func ensureHelper() {
        guard process?.isRunning != true, let script = Self.script else { return }
        let p = Process()
        p.executableURL = Self.python
        p.arguments = ["-I", script.path, Self.model.path, String(threshold)]
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
                self.stopAudio()
                olog("wake helper exited (\(proc.terminationStatus))")
                self.failures += 1
                if self.wanted && self.failures <= 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.apply() }
                }
            }
        }
        do {
            try p.run()
            process = p
            input = inPipe.fileHandleForWriting
            olog("wake helper started (threshold \(threshold))")
        } catch {
            olog("wake helper failed: \(error)")
        }
    }

    private func stopHelper() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        input = nil
    }

    private func line(_ s: String) {
        if s == "READY" { failures = 0; return }
        guard s.hasPrefix("WAKE"), listening, !suspended else { return }
        olog("wake: \(s)")
        onWake()
    }

    // MARK: microphone

    private func startAudio() {
        guard !listening else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { if ok { self.apply() } }
            }
            return
        }
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        converter = AVAudioConverter(from: format, to: target)
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.feed(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            listening = true
            onState(true)
        } catch {
            node.removeTap(onBus: 0)
            olog("wake: mic failed: \(error.localizedDescription)")
        }
    }

    private func stopAudio() {
        guard listening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        listening = false
        onState(false)
    }

    /// Audio thread: convert to 16 kHz int16 and hand it to the helper.
    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let input else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.int16ChannelData?[0], out.frameLength > 0 else { return }
        let data = Data(bytes: ch, count: Int(out.frameLength) * 2)
        writeQueue.async {
            do { try input.write(contentsOf: data) } catch { }
        }
    }
}
