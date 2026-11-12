import Foundation

enum Paths {
    static let support: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orol")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var socket: String { support.appendingPathComponent("orol.sock").path }
    static var config: URL { support.appendingPathComponent("config.json") }
    static var hookBin: URL { support.appendingPathComponent("bin/orol-hook") }
    static var log: URL { support.appendingPathComponent("orol.log") }
    /// A neutral working directory for Orol's own `claude` processes (no project CLAUDE.md).
    static var work: URL {
        let u = support.appendingPathComponent("work")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }
}

func olog(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let h = try? FileHandle(forWritingTo: Paths.log) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: Paths.log)
    }
}

struct OrolConfig: Codable {
    /// Global hotkey that opens the talk-or-type field.
    var hotkey = "ctrl+alt+space"
    /// Speech-to-text language (Apple speech). macOS has no Uzbek recognizer; en-US runs on device.
    var speechLocale = "en-US"
    /// "whisper" (local whisper.cpp; Uzbek and any other language, offline) or "apple".
    var speechEngine = "whisper"
    /// Whisper's language: "uz", "ru", "en", … or "auto".
    var whisperLanguage = "uz"
    /// A file in ~/Library/Application Support/Orol/models, or a full path; empty picks the best one there.
    var whisperModel = ""
    /// Start the microphone when the hotkey opens the field.
    var micOnHotkey = false
    /// Read answers aloud: "off", "voice" (only for spoken requests) or "always".
    var speak = "voice"
    var sounds = true
    var quickModel = "sonnet"
    var agentModel = "sonnet"
    var taskModel = ""
    var taskPermissionMode = "acceptEdits"
    /// Tools the lookup agent may use without asking. Anything else puts a card on the island.
    var agentAllowedTools: [String] = [
        "Read", "Glob", "Grep", "WebSearch", "WebFetch",
    ]
    /// Spoken/typed project name -> folder, for "vazifa <loyiha>: <ish>".
    var projects: [String: String] = [:]
    var claudePath = ""
    /// Home place for weather questions without a city.
    /// "Hey Claude" wake word (hey-claude's shared openWakeWord model).
    var wakeWord = true
    var wakeThreshold = 0.5
    var weatherCity = "Toshkent"
    var weatherLat = 41.2995
    var weatherLon = 69.2401

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OrolConfig()
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        speechLocale = try c.decodeIfPresent(String.self, forKey: .speechLocale) ?? d.speechLocale
        speechEngine = try c.decodeIfPresent(String.self, forKey: .speechEngine) ?? d.speechEngine
        whisperLanguage = try c.decodeIfPresent(String.self, forKey: .whisperLanguage) ?? d.whisperLanguage
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        micOnHotkey = try c.decodeIfPresent(Bool.self, forKey: .micOnHotkey) ?? d.micOnHotkey
        speak = try c.decodeIfPresent(String.self, forKey: .speak) ?? d.speak
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        quickModel = try c.decodeIfPresent(String.self, forKey: .quickModel) ?? d.quickModel
        agentModel = try c.decodeIfPresent(String.self, forKey: .agentModel) ?? d.agentModel
        taskModel = try c.decodeIfPresent(String.self, forKey: .taskModel) ?? d.taskModel
        taskPermissionMode = try c.decodeIfPresent(String.self, forKey: .taskPermissionMode) ?? d.taskPermissionMode
        agentAllowedTools = try c.decodeIfPresent([String].self, forKey: .agentAllowedTools) ?? d.agentAllowedTools
        projects = try c.decodeIfPresent([String: String].self, forKey: .projects) ?? d.projects
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
        wakeWord = try c.decodeIfPresent(Bool.self, forKey: .wakeWord) ?? d.wakeWord
        wakeThreshold = try c.decodeIfPresent(Double.self, forKey: .wakeThreshold) ?? d.wakeThreshold
        weatherCity = try c.decodeIfPresent(String.self, forKey: .weatherCity) ?? d.weatherCity
        weatherLat = try c.decodeIfPresent(Double.self, forKey: .weatherLat) ?? d.weatherLat
        weatherLon = try c.decodeIfPresent(Double.self, forKey: .weatherLon) ?? d.weatherLon
    }

    static func load() -> OrolConfig {
        if let data = try? Data(contentsOf: Paths.config),
           let c = try? JSONDecoder().decode(OrolConfig.self, from: data) {
            return c
        }
        let c = OrolConfig()
        c.save()
        return c
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(self) { try? data.write(to: Paths.config, options: .atomic) }
    }

    /// The `claude` CLI: the configured path, then the usual install places.
    func claudeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [Paths.expand(claudePath), home + "/.local/bin/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", home + "/.claude/local/claude"]
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Environment for child `claude` processes: a GUI app's PATH is nearly empty.
    static func childEnvironment(internalKind: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extra.filter { !parts.contains($0) } + parts).joined(separator: ":")
        env["OROL_INTERNAL"] = internalKind
        return env
    }
}
