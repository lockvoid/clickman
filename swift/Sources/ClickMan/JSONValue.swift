import Foundation

/// A JSON value: what the properties, traits and context of an event are made of.
enum JSONValue: Sendable, Equatable, Encodable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// A value with no JSON form, named by what it is.
    struct NotJSON: Error, CustomStringConvertible {
        let description: String
    }

    /// A host value as JSON: Foundation's JSON types, with `Date`, `URL` and
    /// `UUID` as strings.
    init(_ value: Any) throws {
        switch value {
        case let date as Date:
            self = .string(date.rfc3339)
        case let url as URL:
            self = .string(url.absoluteString)
        case let uuid as UUID:
            self = .string(uuid.uuidString)
        default:
            // Bridging first: an `Optional.none` inside `Any` is NSNull only as an object.
            self = try JSONValue(object: value as AnyObject)
        }
    }

    /// Host properties or traits as a JSON object.
    static func object(from host: [String: Any]) throws -> [String: JSONValue] {
        try host.mapValues(JSONValue.init)
    }

    /// The JSON object `text` holds, e.g. the stored traits.
    static func object(parsing text: String) throws -> [String: JSONValue] {
        guard case .object(let members) = try JSONValue(JSONSerialization.jsonObject(with: Data(text.utf8))) else {
            throw NotJSON(description: "\(text) is not a JSON object")
        }
        return members
    }

    /// The value as JSON text, its keys sorted.
    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let members): try container.encode(members)
        }
    }

    private init(object: AnyObject) throws {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            self = JSONValue(number: number)
        case let string as NSString:
            self = .string(string as String)
        case let array as NSArray:
            self = .array(try array.map(JSONValue.init))
        case let dictionary as NSDictionary:
            self = .object(try JSONValue.members(of: dictionary))
        default:
            throw NotJSON(description: "a \(type(of: object)) is not JSON")
        }
    }

    private init(number: NSNumber) {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
        } else if CFNumberIsFloatType(number) {
            self = .number(number.doubleValue)
        } else {
            self = Int64(number.stringValue).map(JSONValue.integer) ?? .number(number.doubleValue)
        }
    }

    private static func members(of dictionary: NSDictionary) throws -> [String: JSONValue] {
        var members: [String: JSONValue] = [:]
        for (key, value) in dictionary {
            guard let key = key as? String else {
                throw NotJSON(description: "the key \(key) is not a string")
            }
            members[key] = try JSONValue(value)
        }
        return members
    }
}
