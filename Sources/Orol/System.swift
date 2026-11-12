import AppKit
import Carbon
import CoreAudio
import IOKit.ps

/// Which apps are sending sound to the speakers right now (CoreAudio process objects,
/// macOS 14.2+, no permission needed). It can't tell the track, only that it plays.
enum AudioApps {
    private static func value<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ def: T) -> T {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v = def
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : def
    }

    private static func bundleId(_ obj: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let cf else { return "" }
        return cf.takeRetainedValue() as String
    }

    /// Calls and system sounds aren't "now playing".
    private static let ignored: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime", "com.hnc.Discord",
        "com.spotify.client", "com.apple.Music",           // these report themselves with track names
    ]

    /// Regular apps whose processes (or helpers, like Electron's audio service) are playing.
    static func playing() -> [NSRunningApplication] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let bundles = ids.filter { value($0, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0 }.map(bundleId)
        let own = Bundle.main.bundleIdentifier ?? "uz.orol"
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var out: [NSRunningApplication] = []
        for b in bundles where !b.isEmpty && !b.hasPrefix(own) {
            guard let app = apps.first(where: { a in
                guard let id = a.bundleIdentifier else { return false }
                return b == id || b.hasPrefix(id + ".")
            }), let id = app.bundleIdentifier, !ignored.contains(id), !out.contains(app) else { continue }
            out.append(app)
        }
        return out
    }

    static func name(_ app: NSRunningApplication) -> String {
        switch app.bundleIdentifier {
        case "ru.yandex.desktop.music": return "Yandex Musiqa"
        default: return app.localizedName ?? "Ilova"
        }
    }
}

// MARK: - Now playing (Music and Spotify)

/// Follows Music and Spotify through the notifications they broadcast (no permission
/// needed). Controls and artwork go through AppleScript, which macOS asks about once.
final class NowPlaying {
    private let model: IslandModel
    private var artworkKey = ""

    private struct Player {
        let bundleId: String
        let name: String
        let notification: String
    }
    private let players = [
        Player(bundleId: "com.spotify.client", name: "Spotify", notification: "com.spotify.client.PlaybackStateChanged"),
        Player(bundleId: "com.apple.Music", name: "Music", notification: "com.apple.Music.playerInfo"),
    ]

    init(model: IslandModel) {
        self.model = model
        let dnc = DistributedNotificationCenter.default()
        for p in players {
            dnc.addObserver(forName: Notification.Name(p.notification), object: nil, queue: .main) { [weak self] n in
                self?.update(p, n.userInfo ?? [:])
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let self, app.bundleIdentifier == self.model.media?.bundleId else { return }
            self.model.media = nil
        }
        audioTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollAudio() }
    }

    private var audioTimer: Timer?
    private var silentSince: Date?

    private var askedForAccess = false
    private var readingTrack = false

    /// With the Accessibility permission, read the track from the player's own window.
    private func readTrack(_ bundleId: String) {
        guard AXMedia.trusted, !readingTrack else { return }
        readingTrack = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let t = AXMedia.track(bundleId: bundleId)
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingTrack = false
                guard let t, var m = self.model.media, m.bundleId == bundleId, !m.controllable else { return }
                let newTrack = m.title != t.title || m.artist != t.artist
                m.title = t.title
                m.artist = t.artist.isEmpty ? m.appName : t.artist
                if let d = t.duration { m.duration = d }
                if let p = t.position, newTrack || abs((m.currentPosition() ?? -10) - p) > 3 { m.position = p; m.positionAt = Date() }
                if newTrack || m.duration != self.model.media?.duration || m.position != self.model.media?.position { self.model.media = m }
            }
        }
    }

    /// Players without track notifications (Yandex Musiqa, browsers): seen through CoreAudio.
    private func pollAudio() {
        if let m = model.media, !m.controllable { readTrack(m.bundleId) }
        if let m = model.media, m.controllable, m.playing { return }    // Spotify / Music playing wins
        if let app = AudioApps.playing().first, let id = app.bundleIdentifier {
            silentSince = nil
            if model.media?.bundleId != id || model.media?.playing != true {
                let keep = model.media?.bundleId == id ? model.media : nil
                var m = MediaInfo(bundleId: id, appName: AudioApps.name(app), title: keep?.title ?? AudioApps.name(app),
                                  artist: keep?.artist ?? "ijro etilmoqda", playing: true)
                m.controllable = false
                m.artwork = app.icon
                model.media = m
                readTrack(id)
                if !AXMedia.trusted && !askedForAccess {      // once per launch: macOS's own permission dialog
                    askedForAccess = true
                    AXMedia.ask()
                }
            }
        } else if model.media == nil, AXMedia.trusted, !readingTrack,
                  let id = AXMedia.appKeys.keys.first(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
            // a paused player whose window we can read: show its track, so it can be resumed from the island
            readingTrack = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let bar = AXMedia.playerBar(id)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.readingTrack = false
                    guard self.model.media == nil, let bar, !bar.title.isEmpty,
                          let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
                    var m = MediaInfo(bundleId: id, appName: AudioApps.name(app), title: bar.title,
                                      artist: bar.artist.isEmpty ? AudioApps.name(app) : bar.artist, playing: false,
                                      duration: bar.duration, position: bar.position)
                    m.controllable = false
                    m.artwork = app.icon
                    self.model.media = m
                    self.silentSince = Date()
                }
            }
        } else if let m = model.media, !m.controllable {
            if m.playing {
                model.media?.playing = false
                if !AXMedia.trusted { model.media?.artist = "pauza" }
                silentSince = Date()
            } else if let s = silentSince, Date().timeIntervalSince(s) > 30 {
                model.media = nil
            }
        }
    }

    private func update(_ p: Player, _ info: [AnyHashable: Any]) {
        let state = (info["Player State"] as? String ?? "").lowercased()
        let title = info["Name"] as? String ?? ""
        if state == "stopped" || title.isEmpty {
            if model.media?.bundleId == p.bundleId { model.media = nil }
            return
        }
        // A paused player must not replace the one that is playing.
        if state != "playing", let cur = model.media, cur.bundleId != p.bundleId, cur.playing { return }
        silentSince = nil

        var m = MediaInfo(bundleId: p.bundleId, appName: p.name, title: title,
                          artist: info["Artist"] as? String ?? "", playing: state == "playing")
        if let ms = info["Duration"] as? Double { m.duration = ms / 1000 }                  // Spotify, ms
        else if let ms = info["Total Time"] as? Double { m.duration = ms / 1000 }           // Music, ms
        if let pos = info["Playback Position"] as? Double { m.position = pos }              // Spotify, s
        else if let old = model.media, old.bundleId == p.bundleId, old.title == title { m.position = old.currentPosition() }
        else if p.bundleId == "com.apple.Music" { m.position = nil }

        let key = p.bundleId + "|" + title + "|" + m.artist
        if key == artworkKey, let old = model.media { m.artwork = old.artwork }
        if m.artwork == nil { m.artwork = appIcon(p.bundleId) }
        model.media = m
        if key != artworkKey {
            artworkKey = key
            fetchArtwork(p, key: key)
        }
    }

    private func appIcon(_ bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// true when the user already allowed Orol to control this app (never prompts).
    private func automationAllowed(_ bundleId: String) -> Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first != nil else { return false }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        return status == noErr
    }

    private func fetchArtwork(_ p: Player, key: String) {
        guard automationAllowed(p.bundleId) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var image: NSImage?
            if p.bundleId == "com.spotify.client" {
                let src = "tell application \"Spotify\" to return artwork url of current track"
                if let s = NSAppleScript(source: src)?.executeAndReturnError(nil).stringValue,
                   let url = URL(string: s), url.scheme == "https", let data = try? Data(contentsOf: url) {
                    image = NSImage(data: data)
                }
            } else {
                let src = "tell application \"Music\" to return data of artwork 1 of current track"
                if let d = NSAppleScript(source: src)?.executeAndReturnError(nil).data, !d.isEmpty {
                    image = NSImage(data: d)
                }
            }
            guard let image else { return }
            DispatchQueue.main.async {
                guard let self, self.artworkKey == key, self.model.media != nil else { return }
                self.model.media?.artwork = image
            }
        }
    }

    /// action: "playpause" | "next" | "previous"
    /// Did a play/pause sent to a player without AppleScript take effect? Checked by its sound.
    private func verify(_ bundleId: String, action: String) {
        guard action == "playpause" else { return }
        let before = AudioApps.playing().contains { $0.bundleIdentifier == bundleId }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let after = AudioApps.playing().contains { $0.bundleIdentifier == bundleId }
            if after == before {
                let name = AudioApps.name(NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first ?? .current)
                self.model.showFlash(Flash(icon: "exclamationmark.triangle.fill", left: "\(name) javob bermadi",
                                           right: "oynasini ochiq qoldiring", tint: Palette.amber), seconds: 5)
            }
        }
    }

    func control(_ action: String) {
        // Nothing playing right now, but a player we know the shortcuts of is open: use it.
        if model.media == nil, AXMedia.trusted,
           let id = AXMedia.appKeys.keys.first(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
            let key: AXMedia.Key = action == "next" ? .next : action == "previous" ? .previous : .playPause
            let viaButton = AXMedia.pressButton(key, bundleId: id)
            olog("media \(action) -> \(id): button=\(viaButton) bar=\(AXMedia.playerBar(id).map { "\($0.title) prev=\($0.prev != nil) play=\($0.play != nil)" } ?? "nil")")
            if viaButton || AXMedia.pressAppKey(key, bundleId: id) { verify(id, action: action); return }
        }
        if let m = model.media, !m.controllable {
            guard AXMedia.trusted || AXMedia.canSendCommands else {
                AXMedia.ask()
                model.showFlash(Flash(icon: "hand.raised.fill", left: "Ruxsat kerak", right: "Accessibility", tint: Palette.amber), seconds: 5)
                return
            }
            let key: AXMedia.Key = action == "next" ? .next : action == "previous" ? .previous : .playPause
            if !AXMedia.pressButton(key, bundleId: m.bundleId) { AXMedia.press(key) }
            verify(m.bundleId, action: action)
            if action == "playpause" { model.media?.playing.toggle() }
            return
        }
        let running = players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty }
        guard let p = running.first(where: { $0.bundleId == model.media?.bundleId }) ?? running.first else { return }
        let verb = ["playpause": "playpause", "next": "next track", "previous": "previous track"][action] ?? "playpause"
        let src = "tell application \"\(p.name)\" to \(verb)"
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            if let err { olog("media control failed: \(err)") }
        }
    }
}

// MARK: - System alerts (iPhone shows these in the Dynamic Island)

/// Silent mode (output muted), headphones connecting (with AirPods battery when macOS knows
/// it) and unlocking. Everything here is public CoreAudio / distributed notifications.
final class SystemAlerts {
    private let model: IslandModel
    private var device: AudioObjectID = 0
    private var muted: Bool?
    private let queue = DispatchQueue.main

    init(model: IslandModel) {
        self.model = model
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { [weak self] _, _ in
            self?.deviceChanged(announce: true)
        }
        deviceChanged(announce: false)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.model.showFlash(Flash(icon: "lock.open.fill", left: "Qulf ochildi", right: "", tint: .white), seconds: 1.6)
        }
    }

    private static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ def: T) -> T {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v = def
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : def
    }

    private static func name(_ obj: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf) == noErr, let cf else { return "" }
        return cf.takeRetainedValue() as String
    }

    private lazy var muteListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.muteChanged() }
    private var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                      mElement: kAudioObjectPropertyElementMain)

    private func deviceChanged(announce: Bool) {
        if device != 0 { AudioObjectRemovePropertyListenerBlock(device, &muteAddr, queue, muteListener) }
        device = Self.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                          kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
        guard device != 0 else { return }
        AudioObjectAddPropertyListenerBlock(device, &muteAddr, queue, muteListener)
        muted = Self.get(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(0)) != 0
        guard announce else { return }
        let transport = Self.get(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0))
        let bt = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let name = Self.name(device)
        let lower = name.lowercased()
        guard bt || lower.contains("headphone") || lower.contains("airpods") else { return }
        let icon = lower.contains("airpods max") ? "airpodsmax" : lower.contains("airpods pro") ? "airpodspro"
            : lower.contains("airpods") ? "airpods" : "headphones"
        let flash = Flash(icon: icon, left: name, right: "ulandi", tint: .white)
        model.showFlash(flash, seconds: 4)
        if bt { fetchBattery(name, flash) }
    }

    private func muteChanged() {
        let now = Self.get(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(0)) != 0
        guard now != muted else { return }
        muted = now
        model.showFlash(now ? Flash(icon: "bell.slash.fill", left: "Ovozsiz", right: "yoqildi", tint: Palette.bad)
                            : Flash(icon: "bell.fill", left: "Ovozsiz", right: "oʻchdi", tint: .white), seconds: 2)
    }

    /// AirPods report their battery to macOS; system_profiler shows it (takes a second or two).
    private func fetchBattery(_ name: String, _ flash: Flash) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = root["SPBluetoothDataType"] as? [[String: Any]] else { return }
            var levels: [String] = []
            for item in items {
                for entry in (item["device_connected"] as? [[String: Any]]) ?? [] {
                    guard let info = entry[name] as? [String: Any] else { continue }
                    let l = info["device_batteryLevelLeft"] as? String, r = info["device_batteryLevelRight"] as? String
                    if let l, let r { levels.append(l == r ? l : "\(l) · \(r)") }
                    else if let m = info["device_batteryLevelMain"] as? String { levels.append(m) }
                }
            }
            guard let text = levels.first else { return }
            DispatchQueue.main.async {
                guard let self, self.model.flash?.id == flash.id else { return }
                var f = flash
                f.right = text
                self.model.flash = f
            }
        }
    }
}

// MARK: - Battery

final class BatteryMonitor {
    private let model: IslandModel
    private var source: CFRunLoopSource?

    init(model: IslandModel) {
        self.model = model
        refresh(announce: false)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.refresh(announce: true) }
        }, ctx)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    private func refresh(announce: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        var info = BatteryInfo()
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            info.present = true
            info.percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            info.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            info.plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        }
        let old = model.battery
        guard info != old else { return }
        model.battery = info
        guard announce, info.present, old.present else { return }
        if info.plugged && !old.plugged {
            model.showFlash(Flash(icon: "bolt.fill", left: "Quvvatlanmoqda", right: "\(info.percent)%", tint: .green))
        } else if !info.plugged && old.plugged {
            model.showFlash(Flash(icon: "battery.75", left: "Batareyada", right: "\(info.percent)%", tint: .white))
        } else if !info.plugged && info.percent <= 20 && old.percent > 20 {
            model.showFlash(Flash(icon: "battery.25", left: "Batareya kam", right: "\(info.percent)%", tint: .red), seconds: 5)
        }
    }
}

// MARK: - Timers

final class TimerClock {
    private let model: IslandModel
    private let sounds: () -> Bool
    private var tick: Timer?

    init(model: IslandModel, sounds: @escaping () -> Bool) {
        self.model = model
        self.sounds = sounds
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        guard !model.timers.isEmpty else { return }
        let now = Date()
        let done = model.timers.filter { $0.end <= now }
        guard let first = done.first else { return }
        model.timers.removeAll { $0.end <= now }
        let reminder = first.label != "Taymer"
        model.showFlash(Flash(icon: reminder ? "bell.fill" : "timer", left: first.label,
                              right: reminder ? "eslatma" : "vaqt tugadi", tint: emberColor), seconds: reminder ? 10 : 6)
        if sounds() { NSSound(named: "Hero")?.play() }
    }
}

// MARK: - Global hotkey

/// A system-wide hotkey through Carbon's RegisterEventHotKey (no Accessibility permission).
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static var action: (() -> Void)?

    static let keyCodes: [String: UInt32] = [
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28,
        "9": 25, "0": 29, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "`": 50,
    ]

    /// "ctrl+alt+space" -> (key code, Carbon modifiers, "⌃⌥Space")
    static func parse(_ spec: String) -> (UInt32, UInt32, String)? {
        var mods: UInt32 = 0
        var key: UInt32?
        var label = ""
        var keyLabel = ""
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "alt", "opt", "option": mods |= UInt32(optionKey)
            case "shift": mods |= UInt32(shiftKey)
            case "cmd", "command", "meta": mods |= UInt32(cmdKey)
            default:
                guard let k = keyCodes[part] else { return nil }
                key = k
                keyLabel = part.count == 1 ? part.uppercased() : part.prefix(1).uppercased() + part.dropFirst()
            }
        }
        guard let key else { return nil }
        if mods & UInt32(controlKey) != 0 { label += "⌃" }
        if mods & UInt32(optionKey) != 0 { label += "⌥" }
        if mods & UInt32(shiftKey) != 0 { label += "⇧" }
        if mods & UInt32(cmdKey) != 0 { label += "⌘" }
        return (key, mods, label + keyLabel)
    }

    /// Returns the display label, or nil when the key couldn't be registered.
    @discardableResult
    func register(_ spec: String, action: @escaping () -> Void) -> String? {
        unregister()
        guard let (key, mods, label) = Self.parse(spec) else { return nil }
        Self.action = action
        if handlerRef == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { Hotkey.action?() }
                return noErr
            }, 1, &type, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: OSType(0x4F524F4C), id: 1)      // 'OROL'
        var r: EventHotKeyRef?
        let status = RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &r)
        guard status == noErr, let r else { return nil }
        ref = r
        return label
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

// MARK: - Output volume

/// The default output device's volume through CoreAudio (what the volume keys change).
enum SystemVolume {
    private static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)   // 'vmvc' (AudioHardwareService)

    private static var device: AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func address() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: virtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func get() -> Double {
        var addr = address()
        var v = Float32(0.5)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v)
        return Double(v)
    }

    static func set(_ value: Double) {
        let d = device
        var addr = address()
        var v = Float32(min(1, max(0, value)))
        AudioObjectSetPropertyData(d, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if value > 0.005 {                                   // moving the slider up also unmutes
            var m = UInt32(0)
            var ma = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(d, &ma, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }
}
