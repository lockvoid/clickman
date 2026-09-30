import Foundation

/// UUID version 7 (RFC 9562), an event's `messageId`: 48 bits of Unix
/// milliseconds, the version, the RFC 4122 variant and random bits.
enum UUIDv7 {
    /// A new UUIDv7 for `date`, lowercase, e.g. `01926a2e-7b1c-7c3d-9f2e-5b1a2c3d4e5f`.
    static func string(at date: Date) -> String {
        var uuid = UUID().uuid
        let milliseconds = UInt64(bitPattern: date.unixMilliseconds)
        withUnsafeMutableBytes(of: &uuid) { bytes in
            for index in 0..<6 {
                bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (40 - 8 * index))
            }
            bytes[6] = 0x70 | (bytes[6] & 0x0F)
            bytes[8] = 0x80 | (bytes[8] & 0x3F)
        }
        return UUID(uuid: uuid).uuidString.lowercased()
    }
}
