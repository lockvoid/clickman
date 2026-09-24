import Foundation
import os

/// Sends the batches the queue hands out, one at a time, and reports each
/// outcome back so the core can retry with backoff (docs/PROTOCOL.md).
actor Sender {
    private let queue: Queue
    private let endpoint: URL
    private let writeKey: String
    private let session: URLSession
    private let logger: Logger

    init(queue: Queue, endpoint: URL, writeKey: String, session: URLSession, logger: Logger) {
        self.queue = queue
        self.endpoint = endpoint.appending(path: "v1/batch")
        self.writeKey = writeKey
        self.session = session
        self.logger = logger
    }

    /// Sends every batch that is due; `force` sends whatever is waiting.
    func drain(force: Bool) async {
        while let batch = queue.takeBatch(now: Date(), force: force) {
            let (status, retryAfter) = await send(batch)
            queue.complete(batch, status: status, retryAfter: retryAfter, now: Date())

            guard (200..<300).contains(status) else {
                logger.info("ClickMan batch \(batch.id) ended with status \(status); the core retries it")
                return
            }
        }
    }

    private func send(_ batch: Batch) async -> (status: Int, retryAfter: TimeInterval?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(writeKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")

        do {
            let (_, response) = try await session.upload(for: request, from: batch.body)
            guard let response = response as? HTTPURLResponse else {
                return (0, nil)
            }
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return (response.statusCode, retryAfter)
        } catch {
            logger.info("ClickMan could not reach \(self.endpoint, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (0, nil)
        }
    }
}
