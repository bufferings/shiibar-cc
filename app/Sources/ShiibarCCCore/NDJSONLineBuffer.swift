// Line buffering over an NDJSON byte stream (DESIGN.md §4.5: "read line JSON
// with JSONDecoder, doing the line buffering ourselves"). `NWConnection`
// delivers arbitrary-sized chunks, not lines, so this accumulates bytes and
// yields each complete `\n`-terminated line, decoded via the supplied
// decoder. A line that fails to decode (malformed JSON) is dropped rather
// than tearing down the whole buffer — the protocol contract only promises
// well-formed NDJSON, so a decode failure here is a defensive skip, not a
// forward-compat case (unknown fields/events are handled by
// `SubscribeEvent` itself, §4.2).

import Foundation

public final class NDJSONLineBuffer {
    private var pending = Data()

    public init() {}

    /// Feed newly-received bytes; returns any `SubscribeEvent`s completed by
    /// this chunk, in order. Malformed lines are silently skipped.
    public func feed(_ data: Data) -> [SubscribeEvent] {
        pending.append(data)
        var events: [SubscribeEvent] = []
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
            pending.removeSubrange(pending.startIndex...newlineIndex)
            if lineData.isEmpty { continue }
            if let event = try? JSONDecoder().decode(SubscribeEvent.self, from: lineData) {
                events.append(event)
            }
        }
        return events
    }
}
