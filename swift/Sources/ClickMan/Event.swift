import Foundation

/// An event to track: its name and properties.
struct Event: Equatable, Sendable {
    let name: String
    let properties: [String: JSONValue]

    static let appBackgrounded = Event(name: "app_backgrounded", properties: [:])

    static func appOpened(fromBackground: Bool) -> Event {
        Event(name: "app_opened", properties: ["from_background": .bool(fromBackground)])
    }

    /// The event's JSON exactly as it is stored and sent (docs/PROTOCOL.md, Event):
    /// a new UUIDv7, the actor, the time and the context, with the traits when
    /// there are any.
    func body(identity: Identity, context: [String: JSONValue], at date: Date) throws -> String {
        var context = context
        if !identity.traits.isEmpty {
            context["traits"] = .object(identity.traits)
        }
        return try JSONValue.object([
            "type": .string("track"),
            "messageId": .string(UUIDv7.string(at: date)),
            "event": .string(name),
            "externalId": .string(identity.externalId),
            "timestamp": .string(date.rfc3339),
            "properties": .object(properties),
            "context": .object(context),
        ]).json()
    }
}
