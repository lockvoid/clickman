import Foundation

/// One line of the worker protocol, read from stdin.
enum Command {
    case identify(externalId: String)
    case traits([String: Any])
    case track(event: String, properties: [String: Any])
    case reset
    case flush
    case pending

    /// A line that is not a command, and why.
    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    init(_ line: String) throws {
        let request = try Self.object(line)
        switch request["command"] as? String {
        case "identify": self = .identify(externalId: try Self.field("externalId", of: request))
        case "traits": self = .traits(try Self.field("traits", of: request))
        case "track": self = .track(event: try Self.field("event", of: request), properties: try Self.properties(of: request))
        case "reset": self = .reset
        case "flush": self = .flush
        case "pending": self = .pending
        case let other: throw Invalid(description: "unknown command \(other ?? "(none)")")
        }
    }

    private static func object(_ line: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw Invalid(description: "a command is a JSON object")
        }
        return object
    }

    private static func properties(of request: [String: Any]) throws -> [String: Any] {
        request["properties"] == nil ? [:] : try field("properties", of: request)
    }

    private static func field<Value>(_ name: String, of request: [String: Any]) throws -> Value {
        guard let value = request[name] as? Value else {
            throw Invalid(description: "\(name) is missing or not a \(Value.self)")
        }
        return value
    }
}
