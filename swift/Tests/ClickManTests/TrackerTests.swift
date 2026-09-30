import Foundation
import XCTest
@testable import ClickMan

final class TrackerTests: StoreTestCase {
    private let clock = TestClock()
    private var queue: Queue!
    private var tracker: Tracker!

    override func setUpWithError() throws {
        try super.setUpWithError()
        queue = try Queue(path: storage, maxQueue: 10_000)
        tracker = Tracker(queue: queue, bundle: .main, clock: clock.reading, logger: ClickMan.logger)
    }

    private func stored() throws -> [[String: JSONValue]] {
        try queue.oldest(100).map { try JSONValue.object(parsing: $0.body) }
    }

    private func identity() throws -> Identity {
        try queue.write { try $0.identity() }
    }

    func testAnEventIsStoredStampedWithTheActorTheTraitsAndTheContext() throws {
        tracker.identify("user_42")
        tracker.setTraits(["plan": .string("pro")])
        tracker.track(Event(name: "export_completed", properties: ["format": .string("mp4")]))

        let event = try XCTUnwrap(stored().first)
        XCTAssertEqual(event["externalId"], .string("user_42"))
        XCTAssertEqual(event["timestamp"], .string(clock.now.rfc3339))
        XCTAssertEqual(event["properties"], .object(["format": .string("mp4")]))
        XCTAssertEqual(event["context"]?["traits"], .object(["plan": .string("pro")]))
        XCTAssertEqual(event["context"]?["library"]?["name"], .string("clickman-swift"))
        XCTAssertEqual(try queue.waiting(), Waiting(count: 1, oldestCreatedAt: clock.now))
    }

    func testAnEventWithAnInvalidNameIsNotStored() throws {
        for name in ["", "export\tcompleted", String(repeating: "a", count: 201)] {
            tracker.track(Event(name: name, properties: [:]))
        }

        XCTAssertEqual(try queue.count(), 0)
    }

    func testAnInvalidExternalIdLeavesTheActorAsItWas() throws {
        tracker.identify("user_42")
        tracker.identify("")
        tracker.identify("4\n2")

        XCTAssertEqual(try identity().externalId, "user_42")
    }

    func testTraitsMergeIntoTheStoredOnes() throws {
        tracker.setTraits(["plan": .string("pro"), "seats": .integer(3)])
        tracker.setTraits(["plan": .null])

        XCTAssertEqual(try identity().traits, ["seats": .integer(3)])
    }

    func testResetMakesLaterEventsAnonymousWithoutTraits() throws {
        tracker.identify("user_42")
        tracker.setTraits(["plan": .string("pro")])
        tracker.reset()
        tracker.track(Event(name: "signed_out", properties: [:]))

        XCTAssertEqual(try identity(), Identity(externalId: "*", traits: [:], lastLaunch: nil))
        let event = try XCTUnwrap(stored().first)
        XCTAssertEqual(event["externalId"], .string("*"))
        XCTAssertNil(event["context"]?["traits"])
    }

    func testALaunchRecordsItsEventsAndIsRemembered() throws {
        tracker.recordLaunch(Launch(version: "1.0", build: "10"))
        tracker.recordLaunch(Launch(version: "1.0", build: "10"))
        tracker.recordLaunch(Launch(version: "1.1", build: "11"))

        let events = ["app_installed", "app_opened", "app_opened", "app_updated", "app_opened"]
        XCTAssertEqual(try stored().map { $0["event"] }, events.map(JSONValue.string))
        XCTAssertEqual(try identity().lastLaunch, Launch(version: "1.1", build: "11"))
    }
}
