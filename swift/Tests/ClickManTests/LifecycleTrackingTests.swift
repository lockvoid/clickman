import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import ClickMan

final class LifecycleTrackingTests: XCTestCase {
    private var storage: URL!

    override func setUp() {
        storage = FileManager.default.temporaryDirectory
            .appending(path: "clickman-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "queue.sqlite")
        StubServer.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storage.deletingLastPathComponent())
    }

    private func makeClickMan(observesSystem: Bool = false, tracksLifecycle: Bool = true) throws -> ClickMan {
        var configuration = ClickMan.Configuration(endpoint: URL(string: "https://ingest.test")!, writeKey: "ios-key")
        configuration.storage = storage
        configuration.session = StubServer.session()
        configuration.pollInterval = .seconds(3600)
        configuration.observesSystem = observesSystem
        configuration.tracksLifecycle = tracksLifecycle
        return try ClickMan(configuration: configuration)
    }

    private func sentEvents() throws -> [(event: String, properties: [String: Any])] {
        try StubServer.requests.flatMap { request in
            let batch = try JSONSerialization.jsonObject(with: gunzip(request.body)) as! [String: Any]
            return (batch["batch"] as! [[String: Any]]).map { ($0["event"] as! String, $0["properties"] as! [String: Any]) }
        }
    }

    func testTheFirstForegroundEntryIsTheLaunchAndIsNotReportedAgain() async throws {
        let clickMan = try makeClickMan()

        clickMan.lifecycle.willEnterForeground()
        await clickMan.flush()

        let events = try sentEvents()
        XCTAssertEqual(events.map(\.event), ["app_installed", "app_opened"])
        XCTAssertEqual(events.last?.properties["from_background"] as? Bool, false)
    }

    func testLeavingAndReturningIsABackgroundingAndAnOpenFromTheBackground() async throws {
        let clickMan = try makeClickMan()

        clickMan.lifecycle.willEnterForeground()
        clickMan.track("export_completed")
        clickMan.lifecycle.didEnterBackground()
        clickMan.lifecycle.willEnterForeground()
        clickMan.lifecycle.willEnterForeground()
        await clickMan.flush()

        let events = try sentEvents()
        XCTAssertEqual(events.map(\.event), ["app_installed", "app_opened", "export_completed", "app_backgrounded", "app_opened"])
        XCTAssertEqual(events.last?.properties["from_background"] as? Bool, true)
    }

    func testWithoutLifecycleEventsLeavingAndReturningReportNothing() async throws {
        let clickMan = try makeClickMan(tracksLifecycle: false)

        clickMan.track("export_completed")
        clickMan.lifecycle.didEnterBackground()
        clickMan.lifecycle.willEnterForeground()
        await clickMan.flush()

        XCTAssertEqual(try sentEvents().map(\.event), ["export_completed"])
    }

    #if canImport(UIKit)
    func testTheSystemsForegroundNoticeAtLaunchIsNotASecondOpen() async throws {
        let clickMan = try makeClickMan(observesSystem: true)

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await clickMan.flush()

        let events = try sentEvents()
        XCTAssertEqual(events.map(\.event), ["app_installed", "app_opened"])
        XCTAssertEqual(events.last?.properties["from_background"] as? Bool, false)
    }
    #endif
}
