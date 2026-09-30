import Foundation
import GRDB
import XCTest
@testable import ClickMan

final class ClickManTests: StoreTestCase {
    private func makeClickMan(tracksLifecycle: Bool = false, bundle: Bundle = .main, maxQueue: Int = 10_000) throws -> ClickMan {
        var configuration = ClickMan.Configuration.test(storage: storage)
        configuration.tracksLifecycle = tracksLifecycle
        configuration.bundle = bundle
        configuration.maxQueue = maxQueue
        return try ClickMan(configuration: configuration)
    }

    private func release() throws -> Bundle {
        try makeBundle(["CFBundleIdentifier": "com.example.app", "CFBundleShortVersionString": "1.40", "CFBundleVersion": "140"])
    }

    func testTrackedEventsAreSentAsOneGzippedBatch() async throws {
        let clickMan = try makeClickMan()
        clickMan.track("export_completed", properties: ["format": "mp4", "duration": 32.5])
        clickMan.track("paywall_viewed")
        await clickMan.flush()

        let request = try XCTUnwrap(StubServer.requests.first)
        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertEqual(request.url.absoluteString, "https://ingest.test/v1/batch")
        XCTAssertEqual(request.headers["Authorization"], "Bearer ios-key")
        XCTAssertEqual(request.headers["Content-Encoding"], "gzip")
        let events = try StubServer.events()
        XCTAssertEqual(events.map { $0["event"] }, [.string("export_completed"), .string("paywall_viewed")])
        XCTAssertEqual(events.first?["type"], .string("track"))
        XCTAssertEqual(events.first?["properties"], .object(["format": .string("mp4"), "duration": .number(32.5)]))
        XCTAssertEqual(events.first?["externalId"], .string("*"))
        XCTAssertEqual(Set(events.compactMap { $0["messageId"]?.string }).count, 2)
        XCTAssertEqual(clickMan.pendingEvents, 0)
    }

    func testEveryEventCarriesTheStandardContext() async throws {
        let clickMan = try makeClickMan()
        clickMan.track("app_opened")
        await clickMan.flush()

        let context = try XCTUnwrap(StubServer.events().first?["context"])
        XCTAssertEqual(context["library"], .object(["name": .string("clickman-swift"), "version": .string(ClickMan.version)]))
        XCTAssertEqual(context["device"]?["manufacturer"], .string("Apple"))
        XCTAssertNotNil(context["os"]?["version"]?.string)
        XCTAssertNotNil(context["locale"]?.string)
        XCTAssertNotNil(context["timezone"]?.string)
    }

    func testALaunchIsReportedAsAnInstallAndThenAnOpen() async throws {
        let clickMan = try makeClickMan(tracksLifecycle: true, bundle: release())
        await clickMan.flush()

        let events = try StubServer.events()
        XCTAssertEqual(events.map { $0["event"] }, [.string("app_installed"), .string("app_opened")])
        XCTAssertEqual(events.first?["properties"], .object(["version": .string("1.40"), "build": .string("140")]))
        XCTAssertEqual(events.last?["properties"], .object(["from_background": .bool(false)]))
        XCTAssertEqual(events.first?["context"]?["app"]?["build"], .string("140"))
    }

    func testTheFirstLaunchOfANewBuildIsReportedAsAnUpdate() async throws {
        _ = try makeClickMan(tracksLifecycle: true, bundle: release())
        let update = try makeBundle(["CFBundleShortVersionString": "1.41", "CFBundleVersion": "141"])
        let clickMan = try makeClickMan(tracksLifecycle: true, bundle: update)
        await clickMan.flush()

        let events = try StubServer.events()
        XCTAssertEqual(events.map { $0["event"] }, ["app_installed", "app_opened", "app_updated", "app_opened"].map(JSONValue.string))
        XCTAssertEqual(events[2]["properties"], .object([
            "version": .string("1.41"), "build": .string("141"), "previous_version": .string("1.40"), "previous_build": .string("140"),
        ]))
    }

    func testTraitsRideInTheContextUntilRemovedOrReset() async throws {
        let clickMan = try makeClickMan()
        clickMan.setTraits(["plan": "pro"])
        clickMan.track("export_completed")
        clickMan.setTraits(["plan": nil])
        clickMan.track("paywall_viewed")
        clickMan.setTraits(["plan": "max"])
        clickMan.reset()
        clickMan.track("signed_out")
        await clickMan.flush()

        XCTAssertEqual(try StubServer.events().map { $0["context"]?["traits"] }, [.object(["plan": .string("pro")]), nil, nil])
    }

    func testIdentifyAndResetSetTheActorOfLaterEvents() async throws {
        let clickMan = try makeClickMan()
        clickMan.identify("user_42")
        clickMan.track("signed_in")
        clickMan.reset()
        clickMan.track("signed_out")
        await clickMan.flush()

        XCTAssertEqual(try StubServer.events().map { $0["externalId"] }, [.string("user_42"), .string("*")])
    }

    func testDatesUrlsAndUuidsAreSentAsStrings() async throws {
        let clickMan = try makeClickMan()
        let id = UUID()
        clickMan.track("shared", properties: [
            "at": Date(timeIntervalSince1970: 0),
            "link": URL(string: "https://example.com")!,
            "project": id,
            "nested": ["when": Date(timeIntervalSince1970: 0)],
        ])
        await clickMan.flush()

        XCTAssertEqual(try StubServer.events().first?["properties"], .object([
            "at": .string("1970-01-01T00:00:00.000Z"),
            "link": .string("https://example.com"),
            "project": .string(id.uuidString),
            "nested": .object(["when": .string("1970-01-01T00:00:00.000Z")]),
        ]))
    }

    func testAnEventThatCannotBeStoredIsDroppedWithoutHarm() async throws {
        let clickMan = try makeClickMan()
        clickMan.track("broken", properties: ["value": NSObject()])
        clickMan.track("not_finite", properties: ["value": Double.nan])
        clickMan.track("export\ncompleted")
        clickMan.track("fine")
        await clickMan.flush()

        XCTAssertEqual(try StubServer.events().map { $0["event"] }, [.string("fine")])
    }

    func testAFailedSendKeepsTheEventsForARetry() async throws {
        StubServer.reset(status: 503)
        let clickMan = try makeClickMan()
        clickMan.track("a")
        clickMan.track("b")
        await clickMan.flush()
        await clickMan.flush()

        XCTAssertEqual(StubServer.requests.count, 1, "the retry waits out its backoff")
        XCTAssertEqual(clickMan.pendingEvents, 2)
    }

    func testARefusedBatchIsDropped() async throws {
        StubServer.reset(status: 400)
        let clickMan = try makeClickMan()
        clickMan.track("a")
        await clickMan.flush()

        XCTAssertEqual(clickMan.pendingEvents, 0)
    }

    func testTheQueueKeepsTheNewestEventsUpToMaxQueue() async throws {
        let clickMan = try makeClickMan(maxQueue: 3)
        for index in 1...5 {
            clickMan.track("event_\(index)")
        }
        XCTAssertEqual(clickMan.pendingEvents, 3)
        await clickMan.flush()

        XCTAssertEqual(try StubServer.events().map { $0["event"] }, ["event_3", "event_4", "event_5"].map(JSONValue.string))
    }

    func testEventsOlderThanThirtyDaysAreNotSent() async throws {
        _ = try makeClickMan()
        let old = Date().addingTimeInterval(-Sender.maxAge - 60)
        try tamper { db in
            try db.execute(sql: "INSERT INTO events (created_at, body) VALUES (?, ?)", arguments: [old.unixMilliseconds, #"{"event":"stale"}"#])
        }
        let clickMan = try makeClickMan()
        clickMan.track("fresh")
        await clickMan.flush()

        XCTAssertEqual(try StubServer.events().map { $0["event"] }, [.string("fresh")])
        XCTAssertEqual(clickMan.pendingEvents, 0)
    }

    func testTheQueueSurvivesARestartOfTheApp() async throws {
        StubServer.reset(status: 503)
        do {
            let clickMan = try makeClickMan()
            clickMan.identify("user_7")
            clickMan.setTraits(["plan": "pro"])
            clickMan.track("before_restart")
        }
        StubServer.reset()
        let clickMan = try makeClickMan()
        clickMan.track("after_restart")

        XCTAssertEqual(clickMan.pendingEvents, 2)
        await clickMan.flush()
        let events = try StubServer.events()
        XCTAssertEqual(events.map { $0["externalId"] }, [.string("user_7"), .string("user_7")])
        XCTAssertEqual(events.last?["context"]?["traits"], .object(["plan": .string("pro")]))
    }

    func testAStoreTheOldCoreWroteIsAdoptedAndItsEventSent() async throws {
        try writeOldCoreStore(body: #"{"type":"track","event":"before_upgrade"}"#)
        let clickMan = try makeClickMan(tracksLifecycle: true, bundle: release())
        await clickMan.flush()

        let events = try StubServer.events()
        XCTAssertEqual(events.map { $0["event"] }, ["before_upgrade", "app_updated", "app_opened"].map(JSONValue.string))
        XCTAssertEqual(events[1]["properties"]?["previous_version"], .string("1.39"))
        XCTAssertEqual(events.dropFirst().map { $0["externalId"] }, [.string("user_7"), .string("user_7")])
        XCTAssertEqual(events.last?["context"]?["traits"], .object(["plan": .string("pro")]))
        XCTAssertFalse(try inspect { try $0.tableExists("state") })
    }

    func testAStoreOfANewerClickManMakesInitThrow() throws {
        try writeStore(format: 2)

        XCTAssertThrowsError(try makeClickMan())
    }
}
