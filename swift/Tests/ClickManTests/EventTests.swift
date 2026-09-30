import Foundation
import XCTest
@testable import ClickMan

final class EventTests: XCTestCase {
    private let date = Date(unixMilliseconds: 1_727_697_600_123)
    private let anonymous = Identity(externalId: "*", traits: [:], lastLaunch: nil)

    private func body(_ event: Event, identity: Identity, context: [String: JSONValue] = [:]) throws -> [String: JSONValue] {
        try JSONValue.object(parsing: event.body(identity: identity, context: context, at: date))
    }

    func testTheBodyIsATrackOfTheActorAtTheTime() throws {
        let identity = Identity(externalId: "user_42", traits: [:], lastLaunch: nil)
        let body = try body(Event(name: "export_completed", properties: ["format": .string("mp4")]), identity: identity)

        XCTAssertEqual(Set(body.keys), ["type", "messageId", "event", "externalId", "timestamp", "properties", "context"])
        XCTAssertEqual(body["type"], .string("track"))
        XCTAssertEqual(body["event"], .string("export_completed"))
        XCTAssertEqual(body["externalId"], .string("user_42"))
        XCTAssertEqual(body["timestamp"], .string("2024-09-30T12:00:00.123Z"))
        XCTAssertEqual(body["properties"], .object(["format": .string("mp4")]))
    }

    func testTheMessageIdIsAUUIDv7OfTheSameMillisecond() throws {
        let body = try body(Event(name: "a", properties: [:]), identity: anonymous)
        let messageId = try XCTUnwrap(body["messageId"]?.string)

        XCTAssertEqual(try uuidMilliseconds(messageId), date.unixMilliseconds)
        XCTAssertEqual(Array(messageId)[14], "7")
    }

    func testTheContextCarriesTheTraitsOnlyWhenThereAreAny() throws {
        let context: [String: JSONValue] = ["locale": .string("ru-RU")]
        let pro = Identity(externalId: "*", traits: ["plan": .string("pro")], lastLaunch: nil)

        XCTAssertEqual(try body(Event(name: "a", properties: [:]), identity: anonymous, context: context)["context"], .object(context))
        XCTAssertEqual(
            try body(Event(name: "a", properties: [:]), identity: pro, context: context)["context"],
            .object(["locale": .string("ru-RU"), "traits": .object(["plan": .string("pro")])])
        )
    }

    func testTheLifecycleEventsCarryTheirProperties() {
        XCTAssertEqual(Event.appOpened(fromBackground: true), Event(name: "app_opened", properties: ["from_background": .bool(true)]))
        XCTAssertEqual(Event.appBackgrounded, Event(name: "app_backgrounded", properties: [:]))
    }
}
