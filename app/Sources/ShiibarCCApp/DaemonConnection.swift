// Unix-domain-socket subscribe connection to shiibar-ccd (DESIGN.md §4.5):
// `NWConnection` to the state dir's `shiibar-ccd.sock`, sending
// `{"cmd":"subscribe"}` and reading NDJSON lines via `NDJSONLineBuffer`
// (ShiibarCCCore). Reconnect backoff/spawn lifecycle lives in
// `DaemonLifecycleManager`; this type is just the wire-level connection.

import Foundation
import Network
import ShiibarCCCore

/// Coarse connection lifecycle, enough for the lifecycle manager to decide
/// whether to retry/backoff.
enum DaemonConnectionState: Equatable {
    case connecting
    case ready
    case failed
    case cancelled
}

final class DaemonConnection {
    private let socketPath: String
    private let queue = DispatchQueue(label: "cc.shiibar.daemon-connection")
    private var connection: NWConnection?
    private let lineBuffer = NDJSONLineBuffer()

    /// Called on `queue` for every fully-decoded subscribe event.
    var onEvent: ((SubscribeEvent) -> Void)?
    /// Called on `queue` whenever the coarse connection state changes.
    var onStateChange: ((DaemonConnectionState) -> Void)?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func connect() {
        let endpoint = NWEndpoint.unix(path: socketPath)
        // A Unix-domain stream socket: NWParameters.tcp is the standard
        // choice for NWEndpoint.unix in Network.framework (it only selects
        // a reliable byte-stream transport; TCP-specific options don't
        // apply over AF_UNIX). Not independently confirmed against Apple's
        // current documentation in this sandbox (no network access) —
        // verified locally only by `swift build` compiling against the
        // real SDK; real connect behavior is part of the human smoke test.
        let parameters = NWParameters.tcp
        let conn = NWConnection(to: endpoint, using: parameters)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.ready)
                self.sendSubscribe()
                self.receiveLoop()
            case .failed, .waiting:
                self.onStateChange?(.failed)
            case .cancelled:
                self.onStateChange?(.cancelled)
            default:
                break
            }
        }
        onStateChange?(.connecting)
        conn.start(queue: queue)
    }

    /// Send a one-shot request line and close (used for `shutdown`).
    func sendOneShot(_ jsonLine: String, completion: @escaping () -> Void) {
        connect()
        let conn = connection
        // Give `.ready` a moment; sendSubscribe below is skipped since this
        // path is only used right before tearing the connection down.
        queue.asyncAfter(deadline: .now() + 0.05) {
            conn?.send(content: Data((jsonLine + "\n").utf8), completion: .contentProcessed { _ in
                conn?.cancel()
                completion()
            })
        }
    }

    private func sendSubscribe() {
        connection?.send(content: Data("{\"cmd\":\"subscribe\"}\n".utf8), completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for event in self.lineBuffer.feed(data) {
                    self.onEvent?(event)
                }
            }
            if isComplete || error != nil {
                self.onStateChange?(.cancelled)
                return
            }
            self.receiveLoop()
        }
    }

    func cancel() {
        connection?.cancel()
        connection = nil
    }
}
