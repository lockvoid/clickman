import Foundation
import XCTest
@testable import ClickMan

final class RetryDelayTests: XCTestCase {
    func testRetryAfterIsReadInSeconds() {
        XCTAssertEqual(RetryDelay.retryAfter("30"), 30)
        XCTAssertEqual(RetryDelay.retryAfter(" 7 "), 7)
        for unread in [nil, "", "-1", "1.5", "soon", "Wed, 21 Oct 2015 07:28:00 GMT"] {
            XCTAssertNil(RetryDelay.retryAfter(unread), unread ?? "no header")
        }
    }

    func testTheRandomFactorKeepsTheDelayWithinTwentyPercent() {
        let delays = (0..<200).map { _ in RetryDelay.seconds(failures: 1, retryAfter: nil) }

        XCTAssertTrue(delays.allSatisfy { (4...6).contains($0) })
        XCTAssertGreaterThan(Set(delays).count, 1)
    }
}
