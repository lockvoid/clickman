/// What the answer to a batch does to it (docs/PROTOCOL.md, Responses;
/// outcomes.json). Status 0 is no answer at all.
enum Outcome: String, Sendable {
    /// The server has the events; the batch leaves the queue.
    case delivered
    /// The server will never take the batch; it leaves the queue.
    case refused
    /// The batch stays for another attempt.
    case retry

    init(status: Int) {
        switch status {
        case 200..<300: self = .delivered
        case 400, 413, 415: self = .refused
        default: self = .retry
        }
    }
}
