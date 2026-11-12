// orol-hook: the relay Claude Code runs as a hook command.
//
//   "<…>/Orol/bin/orol-hook" <EventName>      (hook JSON on stdin)
//
// It forwards one JSON line to Orol over a Unix socket in
// ~/Library/Application Support/Orol/orol.sock and, for PermissionRequest only,
// waits for Orol's one-line reply and turns it into Claude Code's hookSpecificOutput.
//
// Rules (design from hey-claude's M7 relay):
// - Exit 0 and print nothing on ANY failure: Orol not running, connect timeout, bad
//   input, a socket owned by another user, a bad reply. Nothing that allows a tool is
//   ever printed unless Orol replied after a human click.
// - Deadlines: 2 s for fire-and-forget events, 110 s for PermissionRequest
//   (Orol 108 s < relay 110 s < hook timeout 120 s).
// - When the parent shell dies (the user answered in the terminal), exit at once so
//   Orol sees EOF and drops the card.
// - OROL_INTERNAL set: exit at once (Orol's own `claude` runs).

import Foundation
import Darwin

let strCap = 2048
let deniedMessage = "Orol orqali rad etildi"

func bail() -> Never { exit(0) }

let args = CommandLine.arguments
guard args.count >= 2 else { bail() }
let event = args[1]
guard !event.isEmpty, event.count <= 64, event.allSatisfy({ $0.isLetter || $0.isNumber }) else { bail() }
// Orol's own `claude` runs carry OROL_INTERNAL. The global hooks stay silent for them;
// only the PermissionRequest hook Orol itself attaches (extra argument "agent") is
// forwarded, so their approvals reach the island exactly once.
let ownHook = args.count >= 3 && args[2] == "agent"
let internalKind = ProcessInfo.processInfo.environment["OROL_INTERNAL"]
if internalKind != nil || ownHook {
    guard ownHook, internalKind == "agent" || internalKind == "task", event == "PermissionRequest" else { bail() }
}

let isDecision = (event == "PermissionRequest")
let start = Date()
let deadline = start.addingTimeInterval(isDecision ? 110 : 2)
let originalParent = getppid()

// ---------------------------------------------------------------- read stdin
var raw = FileHandle.standardInput.readDataToEndOfFile()
if raw.starts(with: [0xEF, 0xBB, 0xBF]) { raw = raw.dropFirst(3) }
guard let payloadAny = try? JSONSerialization.jsonObject(with: raw),
      let payload = payloadAny as? [String: Any] else { bail() }

// ---------------------------------------------------------------- sanitize
func sanitize(_ v: Any, depth: Int = 0) -> Any {
    if depth > 24 { return NSNull() }
    switch v {
    case let s as String: return s.count > strCap ? String(s.prefix(strCap)) : s
    case let d as [String: Any]:
        var out: [String: Any] = [:]
        for (k, x) in d { out[k] = sanitize(x, depth: depth + 1) }
        return out
    case let a as [Any]: return a.prefix(200).map { sanitize($0, depth: depth + 1) }
    case is NSNumber, is NSNull: return v
    default: return NSNull()
    }
}

var clean = payload
clean.removeValue(forKey: "tool_response")
for (k, v) in clean { clean[k] = sanitize(v) }

let env = ProcessInfo.processInfo.environment
var envInfo: [String: String] = [:]
for (key, name) in [("entrypoint", "CLAUDE_CODE_ENTRYPOINT"), ("term_program", "TERM_PROGRAM"),
                    ("term_bundle", "__CFBundleIdentifier"), ("vscode_pid", "VSCODE_PID"),
                    ("tmux", "TMUX")] {
    if let v = env[name], !v.isEmpty { envInfo[key] = String(v.prefix(256)) }
}

// AskUserQuestion answers are validated against the untruncated input, so keep it whole.
if isDecision, (payload["tool_name"] as? String) == "AskUserQuestion", let ti = payload["tool_input"] {
    clean["tool_input"] = ti
}

let message: [String: Any] = ["v": 1, "event": event, "payload": clean, "env": envInfo,
                              "ppid": Int(originalParent), "internal": internalKind ?? ""]
guard var line = try? JSONSerialization.data(withJSONObject: message) else { bail() }
line.append(0x0A)

// ---------------------------------------------------------------- connect
let support = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Orol")
let sockPath = ProcessInfo.processInfo.environment["OROL_SOCKET"] ?? support.appendingPathComponent("orol.sock").path

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { bail() }
var one: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(sockPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { bail() }
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    for (i, b) in pathBytes.enumerated() { buf[i] = b }
    buf[pathBytes.count] = 0
}
let flags = fcntl(fd, F_GETFL)
_ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
if rc != 0 {
    guard errno == EINPROGRESS else { bail() }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, 300) == 1 else { bail() }
    var err: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    guard err == 0 else { bail() }
}

// The server must run as our user.
var peerUid: uid_t = 0, peerGid: gid_t = 0
guard getpeereid(fd, &peerUid, &peerGid) == 0, peerUid == getuid() else { bail() }

// ---------------------------------------------------------------- send
func parentGone() -> Bool { getppid() != originalParent }

var sent = 0
while sent < line.count {
    if Date() > deadline || parentGone() { bail() }
    let n = line.withUnsafeBytes { buf in
        Darwin.write(fd, buf.baseAddress! + sent, line.count - sent)
    }
    if n > 0 { sent += n; continue }
    if n < 0 && (errno == EAGAIN || errno == EINTR) {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        _ = poll(&pfd, 1, 100)
        continue
    }
    bail()
}

if !isDecision { close(fd); exit(0) }

// ---------------------------------------------------------------- wait for the decision
var reply = Data()
var buf = [UInt8](repeating: 0, count: 4096)
readLoop: while true {
    if Date() > deadline || parentGone() { close(fd); bail() }
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let p = poll(&pfd, 1, 100)
    if p < 0 && errno != EINTR { bail() }
    if p <= 0 { continue }
    let n = read(fd, &buf, buf.count)
    if n > 0 {
        reply.append(contentsOf: buf[0..<n])
        if reply.count > 256 * 1024 { bail() }
        if reply.contains(0x0A) { break readLoop }
    } else if n == 0 {
        break readLoop
    } else if errno != EAGAIN && errno != EINTR {
        bail()
    }
}
close(fd)

guard let nl = reply.firstIndex(of: 0x0A) ?? (reply.isEmpty ? nil : reply.endIndex),
      let r = try? JSONSerialization.jsonObject(with: reply[reply.startIndex..<nl]) as? [String: Any],
      let kind = r["reply"] as? String else { bail() }

// ---------------------------------------------------------------- build Claude Code's output
let tool = payload["tool_name"] as? String
let toolInput = payload["tool_input"] as? [String: Any]
var decision: [String: Any]

switch kind {
case "allow", "always":
    decision = ["behavior": "allow"]
    if kind == "always", let sugg = payload["permission_suggestions"] as? [Any], !sugg.isEmpty {
        decision["updatedPermissions"] = sugg
    }
    if tool == "ExitPlanMode", let ti = toolInput { decision["updatedInput"] = ti }
case "deny":
    var msg = (r["message"] as? String) ?? ""
    if msg.trimmingCharacters(in: .whitespaces).isEmpty { msg = deniedMessage }
    decision = ["behavior": "deny", "message": String(msg.prefix(1000))]
case "answers":
    // AskUserQuestion: {question text: chosen label}; validated against the original input.
    guard tool == "AskUserQuestion", let ti = toolInput,
          let questions = ti["questions"] as? [[String: Any]],
          let answers = r["answers"] as? [String: String] else { bail() }
    var valid: [String: String] = [:]
    for q in questions {
        guard let text = q["question"] as? String, let a = answers[text],
              let opts = q["options"] as? [[String: Any]] else { bail() }
        let labels = opts.compactMap { $0["label"] as? String }
        let multi = (q["multiSelect"] as? Bool) ?? false
        let picked = multi ? a.components(separatedBy: ", ") : [a]
        guard !picked.isEmpty, picked.allSatisfy({ labels.contains($0) }) else { bail() }
        valid[text] = a
    }
    decision = ["behavior": "allow", "updatedInput": ["questions": questions, "answers": valid]]
default:
    bail()   // "pass": the terminal asks
}

let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
if let data = try? JSONSerialization.data(withJSONObject: out) {
    FileHandle.standardOutput.write(data)
}
exit(0)
