/// The fields of an event a client checks before storing it (docs/PROTOCOL.md,
/// Event; events.json): 1 to `maxScalars` Unicode scalar values, none of them a
/// control character.
enum EventField: String {
    case event
    case externalId

    var maxScalars: Int {
        switch self {
        case .event: 200
        case .externalId: 256
        }
    }

    func accepts(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        return (1...maxScalars).contains(scalars.count)
            && !scalars.contains { $0.properties.generalCategory == .control }
    }
}
