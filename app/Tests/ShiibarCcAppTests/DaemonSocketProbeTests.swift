import Darwin
import XCTest
@testable import ShiibarCcApp

/// The socket side of the attach-time version check (DESIGN.md §4.5 "daemon
/// lifecycle management"), against a socket the test owns in a temp
/// directory: never the real state dir, and no daemon process.
final class DaemonSocketProbeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Short names: a Unix socket path must fit in `sun_path`.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scc-probe-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var socketPath: String { directory.appendingPathComponent("d.sock").path }

    func testSocketPathFitsInSunPath() {
        XCTAssertLessThan(socketPath.utf8.count, MemoryLayout.size(ofValue: sockaddr_un().sun_path))
    }

    /// Binds the socket; listens only when `listen` is true (a bound socket
    /// that does not listen refuses connections).
    private func bindSocket(listen shouldListen: Bool) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        if shouldListen { XCTAssertEqual(Darwin.listen(fd, 4), 0) }
        return fd
    }

    /// Accepts one connection, reads one line, and answers `response`.
    private func serveOnce(_ fd: Int32, response: String) -> XCTestExpectation {
        let served = expectation(description: "served")
        DispatchQueue.global().async {
            let client = accept(fd, nil, nil)
            if client >= 0 {
                var buffer = [UInt8](repeating: 0, count: 1024)
                _ = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
                let bytes = Array(response.utf8)
                _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                close(client)
            }
            served.fulfill()
        }
        return served
    }

    func testMissingSocketFileCountsAsStopped() {
        XCTAssertTrue(DaemonSocketProbe.isStopped(socketPath: socketPath))
        XCTAssertNil(DaemonSocketProbe.fetchVersion(socketPath: socketPath))
    }

    func testRefusedConnectionCountsAsStopped() throws {
        let fd = try bindSocket(listen: false)
        defer { close(fd) }
        XCTAssertTrue(DaemonSocketProbe.isStopped(socketPath: socketPath))
    }

    func testListeningSocketIsNotStopped() throws {
        let fd = try bindSocket(listen: true)
        defer { close(fd) }
        XCTAssertFalse(DaemonSocketProbe.isStopped(socketPath: socketPath))
    }

    func testFetchVersionReadsTheInfoResponse() throws {
        let fd = try bindSocket(listen: true)
        defer { close(fd) }
        let served = serveOnce(fd, response: "{\"ok\":true,\"version\":\"0.9.0\",\"started_at\":1,\"last_report_at\":null}\n")
        XCTAssertEqual(DaemonSocketProbe.fetchVersion(socketPath: socketPath, timeout: 2), "0.9.0")
        wait(for: [served], timeout: 5)
    }

    func testFetchVersionIsNilForAnErrorResponse() throws {
        let fd = try bindSocket(listen: true)
        defer { close(fd) }
        let served = serveOnce(fd, response: "{\"ok\":false,\"error\":\"invalid request\"}\n")
        XCTAssertNil(DaemonSocketProbe.fetchVersion(socketPath: socketPath, timeout: 2))
        wait(for: [served], timeout: 5)
    }
}
