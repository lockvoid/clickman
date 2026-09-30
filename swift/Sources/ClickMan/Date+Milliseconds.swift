import Foundation

extension Date {
    /// Milliseconds since the Unix epoch, to the nearest: an event's `created_at`
    /// and the time in its UUIDv7.
    var unixMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(unixMilliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(unixMilliseconds) / 1000)
    }

    /// RFC 3339 in UTC to the millisecond, e.g. `2026-09-30T12:00:00.123Z`.
    var rfc3339: String {
        let milliseconds = unixMilliseconds
        // ISO8601FormatStyle truncates the binary fraction (…123 ms prints .122), so the milliseconds are written as digits.
        let second = Date(timeIntervalSince1970: TimeInterval(milliseconds / 1000)).formatted(.iso8601)
        return "\(second.dropLast()).\(String(format: "%03lld", milliseconds % 1000))Z"
    }
}
