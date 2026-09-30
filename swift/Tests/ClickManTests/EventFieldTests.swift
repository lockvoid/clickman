import Foundation
import XCTest
@testable import ClickMan

final class EventFieldTests: XCTestCase {
    func testTheLimitCountsUnicodeScalarsNotCharacters() {
        let accented = String(repeating: "e\u{301}", count: 100)

        XCTAssertEqual(accented.count, 100)
        XCTAssertTrue(EventField.event.accepts(accented))
        XCTAssertFalse(EventField.event.accepts(accented + "e\u{301}"))
    }

    func testAnExternalIdMayBeLongerThanAnEventName() {
        let text = String(repeating: "x", count: 256)

        XCTAssertFalse(EventField.event.accepts(text))
        XCTAssertTrue(EventField.externalId.accepts(text))
    }
}
