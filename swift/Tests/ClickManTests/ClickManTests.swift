import Foundation
import XCTest
@testable import ClickMan

final class ClickManTests: XCTestCase {
    private var storage: URL!

    override func setUp() {
        storage = FileManager.default.temporaryDirectory
            .appending(path: "clickman-swift-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "queue.sqlite")
        StubServer.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storage.deletingLastPathComponent())
    }

    private func makeClickMan(tracksLifecycle: Bool = false, bundle: Bundle = .main) throws -> ClickMan {
        var configuration = ClickMan.Configuration(endpoint: URL(string: "https://ingest.test")!, writeKey: "ios-key")
        configuration.storage = storage
        configuration.session = StubServer.session()
        configuration.pollInterval = .seconds(3600)
        configuration.observesSystem = false
        configuration.tracksLifecycle = tracksLifecycle
        configuration.bundle = bundle
        return try ClickMan(configuration: configuration)
    }

    private func makeBundle(version: String, build: String) throws -> Bundle {
        let directory = storage.deletingLastPathComponent().appending(path: "App-\(build).bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.example.app", "CFBundleShortVersionString": version, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appending(path: "Info.plist"))
        return try XCTUnwrap(Bundle(url: directory))
    }

    private func sentEvent(_ index: Int, of events: [[String: Any]]) throws -> [String: Any] {
        try XCTUnwrap(events.indices.contains(index) ? events[index] : nil, "event \(index) was not sent")
    }

    private func sentEvents() throws -> [[String: Any]] {
        try StubServer.requests.flatMap { request in
            let batch = try JSONSerialization.jsonObject(with: gunzip(request.body)) as! [String: Any]
            return batch["batch"] as! [[String: Any]]
        }
    }

    func testTrackedEventsAreSentAsOneGzippedBatch() async throws {
        let clickMan = try makeClickMan()

        clickMan.track("export_completed", properties: ["format": "mp4", "duration": 32.5])
        clickMan.track("paywall_viewed")
        await clickMan.flush()

        XCTAssertEqual(StubServer.requests.count, 1)
        let request = try XCTUnwrap(StubServer.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://ingest.test/v1/batch")
        XCTAssertEqual(request.headers["Authorization"], "Bearer ios-key")
        XCTAssertEqual(request.headers["Content-Encoding"], "gzip")

        let batch = try JSONSerialization.jsonObject(with: gunzip(request.body)) as! [String: Any]
        XCTAssertNotNil(batch["sentAt"] as? String)
        let events = batch["batch"] as! [[String: Any]]
        XCTAssertEqual(events.map { $0["event"] as? String }, ["export_completed", "paywall_viewed"])
        XCTAssertEqual(try sentEvent(0, of: events)["type"] as? String, "track")
        XCTAssertEqual((try sentEvent(0, of: events)["properties"] as? [String: Any])?["format"] as? String, "mp4")
        XCTAssertEqual(try sentEvent(0, of: events)["externalId"] as? String, "*")
        XCTAssertEqual(clickMan.pendingEvents, 0)
    }

    func testEveryEventCarriesTheStandardContext() async throws {
        let clickMan = try makeClickMan()

        clickMan.track("app_opened")
        await clickMan.flush()

        let context = try XCTUnwrap(sentEvents().first?["context"] as? [String: Any])
        XCTAssertEqual((context["library"] as? [String: Any])?["name"] as? String, "clickman-swift")
        XCTAssertEqual((context["library"] as? [String: Any])?["version"] as? String, ClickMan.version)
        XCTAssertEqual((context["device"] as? [String: Any])?["manufacturer"] as? String, "Apple")
        XCTAssertNotNil((context["os"] as? [String: Any])?["version"] as? String)
        XCTAssertNotNil(context["locale"] as? String)
        XCTAssertNotNil(context["timezone"] as? String)
    }

    func testALaunchIsReportedAsAnInstallAndThenAnOpen() async throws {
        let clickMan = try makeClickMan(tracksLifecycle: true, bundle: makeBundle(version: "1.40", build: "140"))
        await clickMan.flush()

        let events = try sentEvents()
        XCTAssertEqual(events.map { $0["event"] as? String }, ["app_installed", "app_opened"])
        XCTAssertEqual(try sentEvent(0, of: events)["properties"] as? [String: String], ["version": "1.40", "build": "140"])
        XCTAssertEqual(try sentEvent(1, of: events)["properties"] as? [String: Bool], ["from_background": false])
        XCTAssertEqual(((try sentEvent(0, of: events)["context"] as? [String: Any])?["app"] as? [String: Any])?["build"] as? String, "140")
    }

    func testTheFirstLaunchOfANewBuildIsReportedAsAnUpdate() async throws {
        _ = try makeClickMan(tracksLifecycle: true, bundle: makeBundle(version: "1.40", build: "140"))
        let clickMan = try makeClickMan(tracksLifecycle: true, bundle: makeBundle(version: "1.41", build: "141"))
        await clickMan.flush()

        let events = try sentEvents()
        XCTAssertEqual(events.map { $0["event"] as? String }, ["app_installed", "app_opened", "app_updated", "app_opened"])
        XCTAssertEqual(
            try sentEvent(2, of: events)["properties"] as? [String: String],
            ["version": "1.41", "build": "141", "previous_version": "1.40", "previous_build": "140"]
        )
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

        let traits = try sentEvents().map { ($0["context"] as? [String: Any])?["traits"] as? [String: String] }
        XCTAssertEqual(traits, [["plan": "pro"], nil, nil])
    }

    func testIdentifyAndResetSetTheActorOfLaterEvents() async throws {
        let clickMan = try makeClickMan()

        clickMan.identify("user_42")
        clickMan.track("signed_in")
        clickMan.reset()
        clickMan.track("signed_out")
        await clickMan.flush()

        XCTAssertEqual(try sentEvents().map { $0["externalId"] as? String }, ["user_42", "*"])
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

        let properties = try XCTUnwrap(sentEvents().first?["properties"] as? [String: Any])
        XCTAssertEqual(properties["at"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(properties["link"] as? String, "https://example.com")
        XCTAssertEqual(properties["project"] as? String, id.uuidString)
        XCTAssertEqual((properties["nested"] as? [String: Any])?["when"] as? String, "1970-01-01T00:00:00.000Z")
    }

    func testAnEventThatIsNotJsonIsDroppedWithoutHarm() async throws {
        let clickMan = try makeClickMan()

        clickMan.track("broken", properties: ["value": NSObject()])
        clickMan.track("fine")
        await clickMan.flush()

        XCTAssertEqual(try sentEvents().map { $0["event"] as? String }, ["fine"])
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

    func testTheQueueSurvivesARestartOfTheApp() async throws {
        StubServer.reset(status: 503)
        do {
            let clickMan = try makeClickMan()
            clickMan.identify("user_7")
            clickMan.track("before_restart")
        }
        StubServer.reset()

        let clickMan = try makeClickMan()

        XCTAssertEqual(clickMan.pendingEvents, 1)
        await clickMan.flush()
        XCTAssertEqual(try sentEvents().map { $0["externalId"] as? String }, ["user_7"])
    }
}
