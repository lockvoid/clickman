/// Who later events are about, their traits, and the last launch the store
/// remembers (protocol/queue.sql, `identity`).
struct Identity: Equatable, Sendable {
    var externalId: String
    var traits: [String: JSONValue]
    var lastLaunch: Launch?

    /// `stored` merged key by key with `changes`: a change replaces a trait whole
    /// and null removes it (traits.json).
    static func merge(traits stored: [String: JSONValue], with changes: [String: JSONValue]) -> [String: JSONValue] {
        changes.reduce(into: stored) { traits, change in
            traits[change.key] = change.value == .null ? nil : change.value
        }
    }
}
