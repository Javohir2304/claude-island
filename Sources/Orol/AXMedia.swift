import AppKit
import ApplicationServices

/// Reads the track from players that don't announce it (Yandex Musiqa) and presses their
/// buttons, through the Accessibility API. Needs Orol to be allowed under
/// Privacy & Security → Accessibility; without it everything here returns nil / false.
enum AXMedia {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "Orol would like to control this computer" dialog (and lists Orol
    /// in Privacy & Security → Accessibility, switched off until you turn it on).
    @discardableResult
    static func ask() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    enum Key: Int32 { case playPause = 16, next = 17, previous = 18 }

    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool
    static var canSendCommands: Bool { mrSend != nil }

    /// Players whose own keyboard shortcuts we know (Yandex Musiqa: K play/pause, N next, P previous).
    static let appKeys: [String: [Key: CGKeyCode]] = [
        "ru.yandex.desktop.music": [.playPause: 40, .next: 45, .previous: 35],
    ]

    /// Presses the player's own button in its window (works only while the window is on the
    /// current desktop: macOS hides other Stage Manager sets from Accessibility).
    static func pressButton(_ key: Key, bundleId: String) -> Bool {
        guard let bar = playerBar(bundleId) else { return false }
        let target: AXUIElement?
        switch key {
        case .previous: target = bar.prev
        case .next: target = bar.next
        case .playPause: target = bar.play
        }
        guard let target else { return false }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    struct Bar {
        var title = "", artist = ""
        var position: Double?, duration: Double?
        var prev: AXUIElement?, play: AXUIElement?, next: AXUIElement?
    }

    /// "5 minutes, 9 seconds" -> 309
    private static func spokenTime(_ s: String) -> Double? {
        var total = 0.0, found = false
        for (word, mul) in [("hour", 3600.0), ("minute", 60.0), ("second", 1.0)] {
            if let r = s.range(of: #"(\d+)\s+"# + word, options: .regularExpression),
               let n = Double(s[r].split(separator: " ").first ?? "") { total += n * mul; found = true }
        }
        return found ? total : nil
    }

    /// The player bar in the window: track and artist links, the time codes and the
    /// previous / play / next buttons (Yandex Musiqa's layout; labels in English or Russian).
    static func playerBar(_ bundleId: String) -> Bar? {
        guard trusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
        let root = appElement(app.processIdentifier)
        guard let wins = attr(root, kAXWindowsAttribute) as? [AXUIElement], !wins.isEmpty else { return nil }
        var bar = Bar()
        for w in wins {
            let nodes = walk(w, maxNodes: 6000)
            guard let pi = nodes.lastIndex(where: { $0.role == "AXButton" && ($0.text.hasPrefix("Previous song") || $0.text.lowercased().hasPrefix("предыдущ")) })
            else { continue }
            bar.prev = nodes[pi].element
            if let k = nodes[(pi + 1)...].firstIndex(where: { $0.role == "AXButton" }) { bar.play = nodes[k].element }
            bar.next = nodes[(pi + 1)...].first(where: { $0.role == "AXButton" && ($0.text.hasPrefix("Next song") || $0.text.lowercased().hasPrefix("следующ")) })?.element
            // the meta links and time codes sit just before the buttons
            for n in nodes[max(0, pi - 40)..<pi] {
                if n.role == "AXLink" {
                    let t = n.text.components(separatedBy: " | ").first ?? ""
                    if t.hasPrefix("Track ") { bar.title = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                    else if t.hasPrefix("Трек ") { bar.title = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                    else if t.hasPrefix("Artist ") { bar.artist = String(t.dropFirst(7)) }
                    else if t.hasPrefix("Исполнитель ") { bar.artist = String(t.dropFirst(12)) }
                }
                if n.classes.contains("Timecode_root_start") { bar.position = spokenTime(n.text) }
                if n.classes.contains("Timecode_root_end") { bar.duration = spokenTime(n.text) }
            }
            return bar
        }
        return nil
    }

    /// Types the player's own shortcut straight into its process, without bringing it forward.
    static func pressAppKey(_ key: Key, bundleId: String) -> Bool {
        guard trusted, let code = appKeys[bundleId]?[key],
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return false }
            e.flags = []
            e.postToPid(app.processIdentifier)
        }
        return true
    }

    private static let mrSend: SendCommand? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(h, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: SendCommand.self)
    }()

    /// The keyboard's media keys: macOS sends them to whatever is playing (Yandex Musiqa,
    /// a browser tab…). Posting them needs the Accessibility permission.
    static func press(_ key: Key) {
        // Preferred: ask macOS's media controller directly (what Control Center's buttons do).
        if let send = mrSend {
            let command: Int32 = key == .playPause ? 2 : key == .next ? 4 : 5
            if send(command, nil) { return }
        }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func str(_ e: AXUIElement, _ name: String) -> String {
        (attr(e, name) as? String) ?? ""
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Chromium (Electron) builds its accessibility tree only when asked.
    static func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return app
    }

    struct Node {
        let element: AXUIElement
        let role: String
        let text: String          // title, description and value joined
        let classes: String       // Chromium's DOM class list
        let depth: Int
    }

    static func walk(_ root: AXUIElement, maxNodes: Int = 6000) -> [Node] {
        var out: [Node] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (e, d) = stack.popLast(), out.count < maxNodes {
            let role = str(e, kAXRoleAttribute)
            let text = [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), str(e, kAXValueAttribute)]
                .filter { !$0.isEmpty }.joined(separator: " | ")
            let classes = ((attr(e, "AXDOMClassList") as? [String]) ?? []).joined(separator: " ")
            out.append(Node(element: e, role: role, text: text, classes: classes, depth: d))
            if d < 60 { for k in children(e).reversed() { stack.append((k, d + 1)) } }
        }
        return out
    }

    /// For tuning: the app's tree as text.
    static func dump(bundleId: String) -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return "not running" }
        let root = appElement(app.processIdentifier)
        Thread.sleep(forTimeInterval: 0.6)
        var lines = ["trusted: \(trusted)"]
        let wins = (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        lines.append("windows: \(wins.count)")
        for w in wins {
            lines.append("WINDOW [\(str(w, kAXTitleAttribute))] minimized=\(String(describing: attr(w, kAXMinimizedAttribute)))")
            for n in walk(w) where !n.text.isEmpty || n.role == "AXButton" {
                lines.append(String(repeating: " ", count: min(n.depth, 30)) + "\(n.role) [\(n.text.prefix(120))] {\(n.classes.prefix(160))}")
            }
        }
        for n in walk(root) where !n.text.isEmpty || !n.classes.isEmpty || n.role == "AXButton" {
            lines.append(String(repeating: " ", count: min(n.depth, 30)) + "\(n.role) [\(n.text.prefix(120))] {\(n.classes.prefix(160))}")
        }
        return lines.joined(separator: "\n")
    }

    struct Track: Equatable {
        var title: String; var artist: String; var playing: Bool?
        var position: Double? = nil; var duration: Double? = nil
    }

    private static let pauseWords = ["pause", "пауза", "приостановить", "to'xtat"]
    private static let playWords = ["play", "воспроизвести", "слушать", "играть"]

    private static func isTime(_ s: String) -> Bool {
        s.range(of: #"^-?\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil
    }

    /// The player bar's track: find the play/pause button, then read the texts around it.
    static func track(bundleId: String) -> Track? {
        if let bar = playerBar(bundleId), !bar.title.isEmpty {
            return Track(title: bar.title, artist: bar.artist, playing: nil, position: bar.position, duration: bar.duration)
        }
        guard trusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
        let nodes = walk(appElement(app.processIdentifier), maxNodes: 5000)
        guard let btnIndex = nodes.firstIndex(where: { n in
            n.role == "AXButton" && {
                let t = n.text.lowercased()
                return pauseWords.contains { t.contains($0) } || playWords.contains { t == $0 || t.hasPrefix($0 + " ") }
            }()
        }) else { return nil }
        let label = nodes[btnIndex].text.lowercased()
        let playing = pauseWords.contains { label.contains($0) }
        // texts before the button inside the same bar (usually title, then artist)
        let depth = nodes[btnIndex].depth
        var texts: [String] = []
        var i = btnIndex - 1
        while i >= 0 && btnIndex - i < 400 {
            let n = nodes[i]
            if n.depth < depth - 6 { break }
            if ["AXStaticText", "AXLink", "AXHeading"].contains(n.role) {
                let t = n.text.components(separatedBy: " | ").first ?? ""
                if t.count > 1 && !isTime(t) && !texts.contains(t) { texts.insert(t, at: 0) }
            }
            i -= 1
        }
        guard let title = texts.first else { return nil }
        return Track(title: title, artist: texts.dropFirst().first ?? "", playing: playing)
    }
}
