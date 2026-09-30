import Foundation
import GRDB
import XCTest
@testable import ClickMan

final class QueueTests: StoreTestCase {
    private static let oldBody = #"{"type":"track","event":"before_upgrade"}"#

    private func identity(_ queue: Queue) throws -> Identity {
        try queue.write { try $0.identity() }
    }

    private func append(_ bodies: [String], to queue: Queue, at date: Date = Date()) throws {
        try queue.write { transaction in
            for body in bodies {
                try transaction.append(body, createdAt: date)
            }
        }
    }

    func testANewStoreIsFormatOneInWALWithTheAnonymousActor() throws {
        let queue = try Queue(path: storage, maxQueue: 10)

        XCTAssertEqual(try identity(queue), Identity(externalId: "*", traits: [:], lastLaunch: nil))
        try inspect { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA journal_mode"), "wal")
        }
    }

    func testAStoreTheOldCoreWroteIsAdopted() throws {
        try writeOldCoreStore(body: Self.oldBody)
        let queue = try Queue(path: storage, maxQueue: 10)

        let launch = Launch(version: "1.39", build: "139")
        XCTAssertEqual(try identity(queue), Identity(externalId: "user_7", traits: ["plan": .string("pro")], lastLaunch: launch))
        XCTAssertEqual(try queue.oldest(10), [QueuedEvent(seq: 1, body: Self.oldBody)])
        try inspect { db in
            XCTAssertFalse(try db.tableExists("state"))
            XCTAssertEqual(try db.indexes(on: "events").map(\.name), [])
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 1)
        }
    }

    func testAStoreOfALaterFormatIsRefused() throws {
        try writeStore(format: 2)

        XCTAssertThrowsError(try Queue(path: storage, maxQueue: 10)) { error in
            guard case ClickManError.storage(let message) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(message.contains("written by a newer ClickMan"), message)
        }
    }

    func testTheQueueKeepsTheNewestEventsUpToItsLimit() throws {
        let queue = try Queue(path: storage, maxQueue: 3)
        try append((1...5).map { #"{"n":\#($0)}"# }, to: queue)

        XCTAssertEqual(try queue.oldest(10).map(\.body), [#"{"n":3}"#, #"{"n":4}"#, #"{"n":5}"#])
    }

    func testWaitingCountsTheEventsAndDatesTheOldest() throws {
        let queue = try Queue(path: storage, maxQueue: 10)
        XCTAssertNil(try queue.waiting())

        try append(["{}"], to: queue, at: Date(unixMilliseconds: 1_000))
        try append(["{}"], to: queue, at: Date(unixMilliseconds: 2_000))
        XCTAssertEqual(try queue.waiting(), Waiting(count: 2, oldestCreatedAt: Date(unixMilliseconds: 1_000)))
    }

    func testAPurgeDeletesOnlyTheEventsCreatedBeforeTheCutoff() throws {
        let queue = try Queue(path: storage, maxQueue: 10)
        try append(["old"], to: queue, at: Date(unixMilliseconds: 1_000))
        try append(["new"], to: queue, at: Date(unixMilliseconds: 2_000))

        try queue.purge(createdBefore: Date(unixMilliseconds: 2_000))
        XCTAssertEqual(try queue.oldest(10).map(\.body), ["new"])
    }

    func testDeletingThroughASeqKeepsTheLaterEvents() throws {
        let queue = try Queue(path: storage, maxQueue: 10)
        try append(["a", "b", "c"], to: queue)

        try queue.delete(through: 2)
        XCTAssertEqual(try queue.oldest(10), [QueuedEvent(seq: 3, body: "c")])
        XCTAssertEqual(try queue.count(), 1)
    }

    func testAReopenedStoreKeepsItsEventsAndIdentity() throws {
        let identity = Identity(externalId: "user_7", traits: ["plan": .string("pro")], lastLaunch: Launch(version: "1.0", build: "10"))
        do {
            let queue = try Queue(path: storage, maxQueue: 10)
            try queue.write { transaction in
                try transaction.setExternalId(identity.externalId)
                try transaction.setTraits(identity.traits)
                try transaction.setLastLaunch(Launch(version: "1.0", build: "10"))
                try transaction.append("{}", createdAt: Date())
            }
        }
        let reopened = try Queue(path: storage, maxQueue: 10)

        XCTAssertEqual(try self.identity(reopened), identity)
        XCTAssertEqual(try reopened.count(), 1)
    }
}
