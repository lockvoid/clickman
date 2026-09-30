import Foundation
import XCTest
@testable import ClickMan

final class SenderTests: StoreTestCase {
    private let clock = TestClock()
    private var queue: Queue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        queue = try Queue(path: storage, maxQueue: 10_000)
    }

    private func sender(flushAt: Int = 20) -> Sender {
        var configuration = ClickMan.Configuration.test(storage: storage)
        configuration.flushAt = flushAt
        return Sender(queue: queue, configuration: configuration, clock: clock.reading, logger: ClickMan.logger)
    }

    private func append(_ count: Int) throws {
        let date = clock.now
        try queue.write { transaction in
            for index in 0..<count {
                try transaction.append(#"{"n":\#(index)}"#, createdAt: date)
            }
        }
    }

    func testABatchIsPostedGzippedWithTheWriteKeyAndTheBodiesVerbatim() async throws {
        try append(2)
        await sender().drain(.everything)

        let request = try XCTUnwrap(StubServer.requests.first)
        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://ingest.test/v1/batch")
        XCTAssertEqual(request.headers["Authorization"], "Bearer ios-key")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Content-Encoding"], "gzip")
        XCTAssertEqual(String(decoding: try gunzip(request.body), as: UTF8.self), #"{"sentAt":"\#(clock.now.rfc3339)","batch":[{"n":0},{"n":1}]}"#)
        XCTAssertEqual(try queue.count(), 0)
    }

    func testAFailedSendKeepsTheRowsAndNothingGoesBeforeTheBackoffEnds() async throws {
        StubServer.reset(status: 503)
        try append(2)
        let sender = sender()

        await sender.drain(.everything)
        await sender.drain(.everything)
        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertEqual(try queue.count(), 2)

        clock.advance(by: 6.001)
        StubServer.answer(202)
        await sender.drain(.everything)
        XCTAssertEqual(StubServer.requests.count, 2)
        XCTAssertEqual(try queue.count(), 0)
    }

    func testNoAnswerIsARetry() async throws {
        StubServer.reset(status: 0)
        try append(1)
        let sender = sender()

        await sender.drain(.everything)
        await sender.drain(.everything)
        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertEqual(try queue.count(), 1)
    }

    func testALongerRetryAfterIsWaitedOut() async throws {
        StubServer.reset(status: 429, retryAfter: "30")
        try append(1)
        let sender = sender()

        await sender.drain(.everything)
        clock.advance(by: 29)
        await sender.drain(.everything)
        XCTAssertEqual(StubServer.requests.count, 1)

        clock.advance(by: 1.001)
        await sender.drain(.everything)
        XCTAssertEqual(StubServer.requests.count, 2)
    }

    func testTheBackoffDoublesAndADeliveryClearsIt() async throws {
        StubServer.reset(status: 500)
        try append(1)
        let sender = sender()

        await sender.drain(.everything)
        clock.advance(by: 6.001)
        await sender.drain(.everything)
        clock.advance(by: 7.9)
        await sender.drain(.everything)
        XCTAssertEqual(StubServer.requests.count, 2, "the second failure waits at least 8 seconds")

        clock.advance(by: 4.2)
        StubServer.answer(202)
        await sender.drain(.everything)
        StubServer.answer(500)
        try append(1)
        await sender.drain(.everything)
        clock.advance(by: 6.001)
        await sender.drain(.everything)
        XCTAssertEqual(StubServer.requests.count, 5, "after a delivery the next failure waits as the first")
    }

    func testARefusedBatchLeavesTheQueue() async throws {
        StubServer.reset(status: 400)
        try append(2)

        await sender().drain(.everything)
        XCTAssertEqual(try queue.count(), 0)
    }

    func testADueDrainWaitsForEnoughEventsOrForTheOldestToAge() async throws {
        let sender = sender(flushAt: 3)
        try append(2)
        await sender.drain(.due)
        XCTAssertEqual(StubServer.requests.count, 0)

        try append(1)
        await sender.drain(.due)
        XCTAssertEqual(StubServer.requests.count, 1, "three are waiting")

        try append(1)
        clock.advance(by: 29.9)
        await sender.drain(.due)
        XCTAssertEqual(StubServer.requests.count, 1)
        clock.advance(by: 0.2)
        await sender.drain(.due)
        XCTAssertEqual(StubServer.requests.count, 2, "the oldest has waited thirty seconds")
    }

    func testEventsOlderThanThirtyDaysAreDeletedUnsent() async throws {
        try append(1)
        clock.advance(by: Sender.maxAge + 1)
        let date = clock.now
        try queue.write { try $0.append(#"{"fresh":true}"#, createdAt: date) }

        await sender().drain(.everything)
        XCTAssertEqual(try StubServer.events(), [.object(["fresh": .bool(true)])])
        XCTAssertEqual(try queue.count(), 0)
    }

    func testADrainSendsBatchesUntilNoneIsDue() async throws {
        try append(150)

        await sender().drain(.everything)
        XCTAssertEqual(try StubServer.batches().map { $0["batch"]?.array?.count }, [100, 50])
        XCTAssertEqual(try queue.count(), 0)
    }

    func testAFailedSendEndsTheDrain() async throws {
        StubServer.reset(status: 503)
        try append(150)

        await sender().drain(.everything)
        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertEqual(try queue.count(), 150)
    }

    func testOneBatchIsInFlightAtATime() async throws {
        StubServer.reset(delay: 0.2)
        try append(2)
        let sender = sender()

        async let first: Void = sender.drain(.everything)
        async let second: Void = sender.drain(.everything)
        _ = await (first, second)
        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertEqual(StubServer.mostInFlight, 1)
        XCTAssertEqual(try queue.count(), 0)
    }
}
