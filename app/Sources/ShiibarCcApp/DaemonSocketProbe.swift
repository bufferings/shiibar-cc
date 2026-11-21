// Blocking one-request helpers over the daemon's Unix-domain socket, for the
// version check at attach time (DESIGN.md §4.5 "daemon lifecycle
// management"): sending `info` and reading its one-line response, and
// telling whether the daemon has stopped (the socket file is gone, or a
// connection to it is refused). Callers run these off the main thread.

import Darwin
import Foundation
import ShiibarCcCore

enum DaemonSocketProbe {
    private enum ConnectResult {
        case connected(Int32)
        /// No socket file, or nothing accepts connections on it.
        case stopped
        case otherError
    }

    private static func connect(socketPath: String, timeout: TimeInterval) -> ConnectResult {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return .otherError }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .otherError }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .connected(fd) }
        let error = errno
        close(fd)
        return (error == ENOENT || error == ECONNREFUSED) ? .stopped : .otherError
    }

    /// The `version` of the daemon's `info` response, nil when no daemon
    /// answered or the response is not a successful `info` response.
    static func fetchVersion(socketPath: String, timeout: TimeInterval = 1.5) -> String? {
        guard case .connected(let fd) = connect(socketPath: socketPath, timeout: timeout) else { return nil }
        defer { close(fd) }
        let request = Array("{\"cmd\":\"info\"}\n".utf8)
        let written = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == request.count else { return nil }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        // One request, one response line (§4.2); stop at the newline, at
        // EOF, on a timeout, or at a size no `info` response reaches.
        while response.count < 65536 {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            response.append(contentsOf: chunk[0..<count])
            if chunk[0..<count].contains(UInt8(ascii: "\n")) { break }
        }
        guard let lineEnd = response.firstIndex(of: UInt8(ascii: "\n")) ?? (response.isEmpty ? nil : response.endIndex) else {
            return nil
        }
        return DaemonVersionCheck.parseInfoVersion(response[response.startIndex..<lineEnd])
    }

    /// Whether the daemon has stopped (§4.5): the socket file is gone, or a
    /// connection to it is refused. Any other connect error does not count
    /// as stopped, so nothing is spawned next to a daemon that may still be
    /// running.
    static func isStopped(socketPath: String) -> Bool {
        switch connect(socketPath: socketPath, timeout: 0.5) {
        case .connected(let fd):
            close(fd)
            return false
        case .stopped:
            return true
        case .otherError:
            return false
        }
    }
}
