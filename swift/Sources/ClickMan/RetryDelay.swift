import Foundation

/// The wait before the next attempt after consecutive failed sends
/// (docs/PROTOCOL.md, Sending; backoff.json): 5 seconds doubled per failure up
/// to 10 minutes, scaled by a random factor, or a longer `Retry-After`.
enum RetryDelay {
    static let jitterRange = 0.8...1.2

    static func seconds(failures: Int, retryAfter: TimeInterval?, jitter: Double = .random(in: jitterRange)) -> TimeInterval {
        let backoff = min(5 * pow(2, Double(failures - 1)), 600) * jitter
        return max(backoff, retryAfter ?? 0)
    }

    /// The seconds a `Retry-After` header asks for; its date form is not read.
    static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              text.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else {
            return nil
        }
        return TimeInterval(text)
    }
}
