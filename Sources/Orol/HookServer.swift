import Foundation
import Darwin

/// The Unix-socket server the `orol-hook` relay talks to. One JSON line in; for a
/// PermissionRequest the connection stays open until Orol replies with one line or
/// either side gives up.
final class HookServer {
    final class Connection {
        fileprivate let fd: Int32
        fileprivate var source: DispatchSourceRead?
        fileprivate var buffer = Data()
        fileprivate var delivered = false
        private(set) var closed = false
        /// Called on the main queue when the relay goes away before Orol answered.
        var onPeerClosed: (() -> Void)?

        fileprivate init(fd: Int32) { self.fd = fd }

        /// Send the decision line and close.
        func reply(_ obj: [String: Any]) {
            guard !closed else { return }
            if var data = try? JSONSerialization.data(withJSONObject: obj) {
                data.append(0x0A)
                data.withUnsafeBytes { buf in
                    var off = 0
                    while off < data.count {
                        let n = Darwin.write(fd, buf.baseAddress! + off, data.count - off)
                        if n > 0 { off += n } else if errno != EINTR && errno != EAGAIN { break }
                    }
                }
            }
            close()
        }

        private let closeLock = NSLock()

        func close() {
            closeLock.lock()
            let already = closed
            closed = true
            closeLock.unlock()
            guard !already else { return }
            onPeerClosed = nil
            if let s = source { s.cancel() } else { Darwin.close(fd) }
        }
    }

    struct Message {
        let event: String
        let payload: [String: Any]
        let env: [String: String]
        let internalKind: String
        let connection: Connection?     // non-nil only while a decision is awaited
    }

    enum StartError: Error { case alreadyRunning, failed(String) }

    var handler: ((Message) -> Void)?
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "orol.hookserver")
    private let path: String

    init(path: String = Paths.socket) { self.path = path }

    private func makeAddr() -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }

    func start() throws {
        guard var addr = makeAddr() else { throw StartError.failed("socket path too long") }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)

        // Another Orol already listening?
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        if probe >= 0 {
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, len) }
            }
            Darwin.close(probe)
            if rc == 0 { throw StartError.alreadyRunning }
        }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.failed("socket()") }
        let old = umask(0o177)
        let b = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        umask(old)
        guard b == 0 else { Darwin.close(fd); throw StartError.failed("bind: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { Darwin.close(fd); throw StartError.failed("listen()") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFd = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.resume()
        acceptSource = src
    }

    func stop() {
        acceptSource?.cancel()
        if listenFd >= 0 { Darwin.close(listenFd); listenFd = -1 }
        unlink(path)
    }

    private func acceptAll() {
        while true {
            let cfd = accept(listenFd, nil, nil)
            if cfd < 0 { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(cfd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(cfd); continue }
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL) | O_NONBLOCK)
            let conn = Connection(fd: cfd)
            let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: queue)
            conn.source = src
            src.setEventHandler { [weak self] in self?.readable(conn) }
            src.setCancelHandler { Darwin.close(cfd) }
            src.resume()
        }
    }

    private func readable(_ conn: Connection) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(conn.fd, &buf, buf.count)
            if n > 0 {
                if !conn.delivered {
                    conn.buffer.append(contentsOf: buf[0..<n])
                    if conn.buffer.count > 2_000_000 { conn.close(); return }
                    if let nl = conn.buffer.firstIndex(of: 0x0A) {
                        let line = conn.buffer[conn.buffer.startIndex..<nl]
                        conn.delivered = true
                        conn.buffer = Data()
                        deliver(Data(line), conn)
                    }
                }
                continue
            }
            if n == 0 {                               // the relay went away
                let cb = conn.onPeerClosed
                conn.close()
                if let cb { DispatchQueue.main.async(execute: cb) }
                return
            }
            if errno == EAGAIN || errno == EINTR { return }
            conn.close()
            return
        }
    }

    private func deliver(_ line: Data, _ conn: Connection) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = obj["event"] as? String,
              let payload = obj["payload"] as? [String: Any] else { conn.close(); return }
        let env = obj["env"] as? [String: String] ?? [:]
        let kind = obj["internal"] as? String ?? ""
        let waits = (event == "PermissionRequest")
        if !waits { conn.close() }
        let msg = Message(event: event, payload: payload, env: env, internalKind: kind,
                          connection: waits ? conn : nil)
        DispatchQueue.main.async { [weak self] in
            if let h = self?.handler { h(msg) } else { conn.close() }
        }
    }
}
