import Network
import XCTest
@testable import ClickMan

final class NetworkReturnTests: XCTestCase {
    func testASatisfiedPathAfterOneThatWasNotIsAReturn() {
        XCTAssertTrue(NetworkReturn.isReturn(from: .unsatisfied, to: .satisfied))
        XCTAssertTrue(NetworkReturn.isReturn(from: .requiresConnection, to: .satisfied))
    }

    func testTheFirstReportAndEveryOtherChangeAreNot() {
        XCTAssertFalse(NetworkReturn.isReturn(from: nil, to: .satisfied))
        XCTAssertFalse(NetworkReturn.isReturn(from: .satisfied, to: .satisfied))
        XCTAssertFalse(NetworkReturn.isReturn(from: .satisfied, to: .unsatisfied))
        XCTAssertFalse(NetworkReturn.isReturn(from: .unsatisfied, to: .requiresConnection))
    }
}
