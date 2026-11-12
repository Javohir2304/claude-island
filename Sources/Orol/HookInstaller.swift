import Foundation
import CryptoKit

/// Adds Orol's hook entries to the user's global Claude Code settings, next to the
/// hooks already there, and removes exactly those entries again. Nothing is written
/// until the user confirms in the app.
enum HookInstaller {
    /// event, timeout (s), needs a tool matcher
    static let events: [(String, Int, Bool)] = [
        ("SessionStart", 10, false), ("SessionEnd", 10, false), ("UserPromptSubmit", 10, false),
        ("PreToolUse", 10, true), ("PostToolUse", 10, true), ("PermissionRequest", 120, true),
        ("Notification", 10, false), ("Stop", 10, false), ("SubagentStop", 10, false),
    ]

    enum InstallError: LocalizedError {
        case unreadable(String), badShape, noRelay
        var errorDescription: String? {
            switch self {
            case .unreadable(let p): return "Sozlamalar faylini oʻqib boʻlmadi: \(p)"
            case .badShape: return "settings.json ichidagi \"hooks\" kutilgan koʻrinishda emas, shuning uchun unga tegilmadi."
            case .noRelay: return "orol-hook dasturi topilmadi."
            }
        }
    }

    static var settingsURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: Paths.expand(dir)).appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var relayPath: String { Paths.hookBin.path }

    static func command(for event: String, own: Bool = false) -> String {
        "\"\(relayPath)\" \(event)" + (own ? " agent" : "")
    }

    /// The relay bundled with the app (next to the main executable).
    static var bundledRelay: URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("orol-hook"),
                          exe.deletingLastPathComponent().appendingPathComponent("orol-hook")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Copy the relay to a stable place only Orol writes. Compared by hash, not date.
    @discardableResult
    static func installRelay() -> Bool {
        guard let src = bundledRelay, let data = try? Data(contentsOf: src) else {
            return FileManager.default.isExecutableFile(atPath: relayPath)
        }
        let dst = Paths.hookBin
        if let old = try? Data(contentsOf: dst), SHA256.hash(data: old) == SHA256.hash(data: data) { return true }
        do {
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = dst.deletingLastPathComponent().appendingPathComponent(".orol-hook.tmp")
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(dst, withItemAt: tmp)
            return true
        } catch {
            olog("relay install failed: \(error)")
            return false
        }
    }

    private static func read() throws -> [String: Any] {
        let url = settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard var data = try? Data(contentsOf: url) else { throw InstallError.unreadable(url.path) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.unreadable(url.path)
        }
        return obj
    }

    private static func isOurs(_ hook: Any) -> Bool {
        guard let h = hook as? [String: Any], let c = h["command"] as? String else { return false }
        return c.contains(relayPath)
    }

    /// groups without our individual hook entries; groups we emptied are dropped.
    private static func strip(_ groups: [Any]) -> (groups: [Any], found: Bool) {
        var out: [Any] = []
        var found = false
        for g in groups {
            guard var group = g as? [String: Any], let hooks = group["hooks"] as? [Any] else { out.append(g); continue }
            let kept = hooks.filter { !isOurs($0) }
            if kept.count != hooks.count { found = true }
            if kept.isEmpty && kept.count != hooks.count { continue }
            group["hooks"] = kept
            out.append(group)
        }
        return (out, found)
    }

    static func isInstalled() -> Bool {
        guard let s = try? read(), let hooks = s["hooks"] as? [String: Any] else { return false }
        for (_, v) in hooks {
            if let groups = v as? [Any], strip(groups).found { return true }
        }
        return false
    }

    private static func write(_ settings: [String: Any]) throws {
        let url = settingsURL
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("settings.json.orol-backup-\(f.string(from: Date()))")
            try? fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func install() throws {
        guard installRelay() else { throw InstallError.noRelay }
        var settings = try read()
        var hooks: [String: Any] = [:]
        if let h = settings["hooks"] {
            guard let dict = h as? [String: Any] else { throw InstallError.badShape }
            hooks = dict
        }
        for (event, timeout, matcher) in events {
            var groups: [Any] = []
            if let g = hooks[event] {
                guard let arr = g as? [Any] else { throw InstallError.badShape }
                groups = strip(arr).groups
            }
            let hook: [String: Any] = ["type": "command", "command": command(for: event), "timeout": timeout]
            let group: [String: Any] = matcher ? ["matcher": "*", "hooks": [hook]] : ["hooks": [hook]]
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try write(settings)
    }

    static func uninstall() throws {
        var settings = try read()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        var changed = false
        for (event, v) in hooks {
            guard let arr = v as? [Any] else { continue }
            let r = strip(arr)
            guard r.found else { continue }
            changed = true
            if r.groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = r.groups }
        }
        guard changed else { return }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try write(settings)
    }

    /// `--settings` JSON for Orol's own agent and tasks: one PermissionRequest hook, so
    /// their approvals reach the island whether or not the global hooks are installed.
    static func ownHookSettings() -> String {
        let obj: [String: Any] = ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [
            ["type": "command", "command": command(for: "PermissionRequest", own: true), "timeout": 120]]]]]]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
