import Foundation

/// The oldest waiting events, sent together (docs/PROTOCOL.md, Sending).
struct Batch: Equatable, Sendable {
    static let maxEvents = 100
    static let maxBytes = 900_000

    let bodies: [String]
    /// The `seq` of the newest event taken: the batch leaves the queue through it.
    let lastSeq: Int64

    /// The batch the oldest of `events`, oldest first, make; nil when none wait.
    init?(taking events: [QueuedEvent]) {
        let count = Self.count(taking: events.map(\.body), maxEvents: Self.maxEvents, maxBytes: Self.maxBytes)
        let taken = events.prefix(count)
        guard let last = taken.last else {
            return nil
        }
        bodies = taken.map(\.body)
        lastSeq = last.seq
    }

    /// How many of `bodies` a batch takes: at most `maxEvents`, while the bodies
    /// joined by commas stay within `maxBytes` UTF-8 bytes; the oldest is taken
    /// even alone over the limit (batches.json).
    static func count(taking bodies: [String], maxEvents: Int, maxBytes: Int) -> Int {
        var taken = 0
        var bytes = 0
        for body in bodies.prefix(maxEvents) {
            bytes += (taken == 0 ? 0 : 1) + body.utf8.count
            guard taken == 0 || bytes <= maxBytes else {
                break
            }
            taken += 1
        }
        return taken
    }

    /// The request body before gzip, the bodies verbatim.
    func payload(sentAt: Date) -> Data {
        Data(#"{"sentAt":"\#(sentAt.rfc3339)","batch":[\#(bodies.joined(separator: ","))]}"#.utf8)
    }
}
