import Foundation
import XCTest
@testable import ClickMan

final class BatchTests: XCTestCase {
    private func events(_ count: Int) -> [QueuedEvent] {
        (1...count).map { QueuedEvent(seq: Int64($0 * 10), body: #"{"n":\#($0)}"#) }
    }

    func testTheBatchEndsAtTheNewestEventTaken() throws {
        let batch = try XCTUnwrap(Batch(taking: events(3)))

        XCTAssertEqual(batch.bodies, events(3).map(\.body))
        XCTAssertEqual(batch.lastSeq, 30)
    }

    func testABatchTakesAtMostAHundred() throws {
        let batch = try XCTUnwrap(Batch(taking: events(150)))

        XCTAssertEqual(batch.bodies.count, 100)
        XCTAssertEqual(batch.lastSeq, 1_000)
    }

    func testNoWaitingEventsMakeNoBatch() {
        XCTAssertNil(Batch(taking: []))
    }

    func testThePayloadCarriesTheBodiesVerbatim() throws {
        let batch = try XCTUnwrap(Batch(taking: [QueuedEvent(seq: 1, body: #"{"b":1,"a":2}"#), QueuedEvent(seq: 2, body: #"{"x":"é"}"#)]))
        let payload = String(decoding: batch.payload(sentAt: Date(unixMilliseconds: 1_727_697_600_123)), as: UTF8.self)

        XCTAssertEqual(payload, #"{"sentAt":"2024-09-30T12:00:00.123Z","batch":[{"b":1,"a":2},{"x":"é"}]}"#)
    }
}
