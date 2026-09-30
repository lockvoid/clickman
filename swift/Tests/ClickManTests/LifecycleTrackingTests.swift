import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import ClickMan

final class LifecycleTrackingTests: StoreTestCase {
    private func makeClickMan(observesSystem: Bool = false, tracksLifecycle: Bool = true) throws -> ClickMan {
        var configuration = ClickMan.Configuration.test(storage: storage)
        configuration.observesSystem = observesSystem
        configuration.tracksLifecycle = tracksLifecycle
        return try ClickMan(configuration: configuration)
    }

    private func sentEvents() throws -> [(event: JSONValue?, properties: JSONValue?)] {
        try StubServer.events().map { ($0["event"], $0["properties"]) }
    }

    func testTheFirstForegroundEntryIsTheLaunchAndIsNotReportedAgain() async throws {
        let clickMan = try makeClickMan()

        clickMan.lifecycle.willEnterForeground()
        await clickMan.flush()

        let events = try sentEvents()
        XCTAssertEqual(events.map(\.event), [.string("app_installed"), .string("app_opened")])
        XCTAssertEqual(events.last?.properties, .object(["from_background": .bool(false)]))
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
        let names = ["app_installed", "app_opened", "export_completed", "app_backgrounded", "app_opened"]
        XCTAssertEqual(events.map(\.event), names.map(JSONValue.string))
        XCTAssertEqual(events.last?.properties, .object(["from_background": .bool(true)]))
    }

    func testWithoutLifecycleEventsLeavingAndReturningReportNothing() async throws {
        let clickMan = try makeClickMan(tracksLifecycle: false)

        clickMan.track("export_completed")
        clickMan.lifecycle.didEnterBackground()
        clickMan.lifecycle.willEnterForeground()
        await clickMan.flush()

        XCTAssertEqual(try sentEvents().map(\.event), [.string("export_completed")])
    }

    #if canImport(UIKit)
    func testTheSystemsForegroundNoticeAtLaunchIsNotASecondOpen() async throws {
        let clickMan = try makeClickMan(observesSystem: true)

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await clickMan.flush()

        let events = try sentEvents()
        XCTAssertEqual(events.map(\.event), [.string("app_installed"), .string("app_opened")])
        XCTAssertEqual(events.last?.properties, .object(["from_background": .bool(false)]))
    }
    #endif
}
