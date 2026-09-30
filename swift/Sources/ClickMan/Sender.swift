import Foundation
import os

/// Which waiting events a drain sends.
enum DrainScope: Sendable {
    /// Only once enough are waiting or the oldest has waited long enough.
    case due
    /// Everything waiting: a flush, leaving the foreground, the network returning.
    case everything
}

/// Sends the waiting events in batches, one in flight at a time, and backs off
/// after a failed send (docs/PROTOCOL.md, Sending). The failures are counted in
/// memory, so a restarted client sends at once.
actor Sender {
    /// How long an event may wait unsent before it is deleted.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// Whether the next batch may go out.
    private enum Pace {
        /// The last batch left the queue.
        case open
        /// `failures` batches in a row stayed; the next attempt waits until `nextAttemptAt`.
        case backingOff(failures: Int, nextAttemptAt: Date)
    }

    /// What the server said to a batch; status 0 when nothing came back.
    private struct Answer {
        let status: Int
        let retryAfter: TimeInterval?
        let detail: String
    }

    private let queue: Queue
    private let request: URLRequest
    private let session: URLSession
    private let flushAt: Int
    private let flushInterval: Duration
    private let clock: @Sendable () -> Date
    private let logger: Logger
    private var pace = Pace.open
    private var drains: Task<Void, Never>?

    init(queue: Queue, configuration: ClickMan.Configuration, clock: @escaping @Sendable () -> Date, logger: Logger) {
        self.queue = queue
        self.request = Self.request(endpoint: configuration.endpoint, writeKey: configuration.writeKey)
        self.session = configuration.session
        self.flushAt = configuration.flushAt
        self.flushInterval = configuration.flushInterval
        self.clock = clock
        self.logger = logger
    }

    /// Sends batches until none is due or a send fails, after the drains asked for before it.
    func drain(_ scope: DrainScope) async {
        let previous = drains
        let current = Task {
            await previous?.value
            await sendBatches(scope)
        }
        drains = current
        await current.value
    }

    private func sendBatches(_ scope: DrainScope) async {
        do {
            while let batch = try dueBatch(scope) {
                guard try await send(batch) != .retry else {
                    return
                }
            }
        } catch {
            logger.error("ClickMan could not send what is waiting: \(String(describing: error), privacy: .public)")
        }
    }

    /// The batch to send now: none while a retry waits, while nothing is due, or when nothing waits.
    private func dueBatch(_ scope: DrainScope) throws -> Batch? {
        let now = clock()
        guard mayAttempt(at: now), try isDue(scope, at: now) else {
            return nil
        }
        try queue.purge(createdBefore: now.addingTimeInterval(-Self.maxAge))
        return Batch(taking: try queue.oldest(Batch.maxEvents))
    }

    private func mayAttempt(at date: Date) -> Bool {
        switch pace {
        case .open: true
        case .backingOff(_, let nextAttemptAt): date >= nextAttemptAt
        }
    }

    private func isDue(_ scope: DrainScope, at date: Date) throws -> Bool {
        guard let waiting = try queue.waiting() else {
            return false
        }
        switch scope {
        case .everything:
            return true
        case .due:
            return waiting.count >= flushAt || .seconds(date.timeIntervalSince(waiting.oldestCreatedAt)) >= flushInterval
        }
    }

    private func send(_ batch: Batch) async throws -> Outcome {
        var request = self.request
        request.httpBody = try Gzip.compress(batch.payload(sentAt: clock()))
        let answer = await post(request)
        let outcome = Outcome(status: answer.status)
        try settle(batch, outcome: outcome, answer: answer)
        return outcome
    }

    private func post(_ request: URLRequest) async -> Answer {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return Answer(status: 0, retryAfter: nil, detail: "the answer was not HTTP")
            }
            let retryAfter = RetryDelay.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            return Answer(status: http.statusCode, retryAfter: retryAfter, detail: String(decoding: data.prefix(512), as: UTF8.self))
        } catch {
            return Answer(status: 0, retryAfter: nil, detail: error.localizedDescription)
        }
    }

    private func settle(_ batch: Batch, outcome: Outcome, answer: Answer) throws {
        switch outcome {
        case .delivered:
            try remove(batch)
        case .refused:
            logger.error("ClickMan dropped \(batch.bodies.count) events the server refused with \(answer.status): \(answer.detail, privacy: .public)")
            try remove(batch)
        case .retry:
            backOff(after: answer)
        }
    }

    private func remove(_ batch: Batch) throws {
        try queue.delete(through: batch.lastSeq)
        pace = .open
    }

    private func backOff(after answer: Answer) {
        let failures = failures + 1
        let delay = RetryDelay.seconds(failures: failures, retryAfter: answer.retryAfter)
        pace = .backingOff(failures: failures, nextAttemptAt: clock().addingTimeInterval(delay))
        logger.error("ClickMan will retry a batch in \(Int(delay.rounded(.up)))s, the answer was \(answer.status): \(answer.detail, privacy: .public)")
    }

    private var failures: Int {
        switch pace {
        case .open: 0
        case .backingOff(let failures, _): failures
        }
    }

    private static func request(endpoint: URL, writeKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint.appending(path: "v1/batch"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(writeKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        return request
    }
}
