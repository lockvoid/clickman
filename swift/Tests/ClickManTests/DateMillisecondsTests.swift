import Foundation
import XCTest
@testable import ClickMan

final class DateMillisecondsTests: XCTestCase {
    func testRFC3339WritesTheMillisecondsExactly() {
        XCTAssertEqual(Date(unixMilliseconds: 1_727_697_600_123).rfc3339, "2024-09-30T12:00:00.123Z")
        XCTAssertEqual(Date(unixMilliseconds: 1_727_697_600_001).rfc3339, "2024-09-30T12:00:00.001Z")
        XCTAssertEqual(Date(unixMilliseconds: 1_727_697_600_999).rfc3339, "2024-09-30T12:00:00.999Z")
        XCTAssertEqual(Date(unixMilliseconds: 0).rfc3339, "1970-01-01T00:00:00.000Z")
    }

    func testMillisecondsRoundToTheNearest() {
        XCTAssertEqual(Date(timeIntervalSince1970: 1_727_697_600.1234).unixMilliseconds, 1_727_697_600_123)
        XCTAssertEqual(Date(timeIntervalSince1970: 1_727_697_600.1236).unixMilliseconds, 1_727_697_600_124)
        XCTAssertEqual(Date(unixMilliseconds: 1_727_697_600_123).unixMilliseconds, 1_727_697_600_123)
    }
}
