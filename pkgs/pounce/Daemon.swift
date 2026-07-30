import Foundation

// MARK: - Talking to the resident daemon

// One round-trip over the unix socket: write a request, read the reply, hang up.
//
// Several client paths need this — `focus` and `--transform` forward their op to
// the daemon because only it holds the Accessibility grant, `doctor` asks for
// live state because only it knows whether the hotkey has fired, and `run`
// dispatches an item because only it owns the window. They had a byte-identical
// copy of this each; the verb and the reply parsing are the only real
// differences, so those stay with the callers and the plumbing lives here.
enum Daemon {
    // The reply with trailing newline/whitespace trimmed, or nil when no daemon
    // is listening (socket missing, refused, or it hung up without answering).
    // Callers treat nil as "no daemon" and either fall back locally or say so.
    static func request(_ payload: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            SocketConfig.path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(strlen(cstr) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addrLen) }
        }) == 0
        guard connected else { return nil }

        let data = Data(payload.utf8)
        data.withUnsafeBytes { ptr in _ = write(fd, ptr.baseAddress!, data.count) }
        shutdown(fd, SHUT_WR)

        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0..<n])
        }
        guard let text = String(data: reply, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
