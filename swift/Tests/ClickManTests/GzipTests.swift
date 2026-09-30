import Foundation
import XCTest
@testable import ClickMan

final class GzipTests: XCTestCase {
    func testABatchIsOneGzipMemberThatInflatesBack() throws {
        let text = Data(String(repeating: #"{"type":"track","event":"export_completed"}"#, count: 200).utf8)
        let zipped = try Gzip.compress(text)

        XCTAssertEqual(Array(zipped.prefix(2)), [0x1f, 0x8b])
        XCTAssertEqual(zipped.suffix(4).reversed().reduce(0) { $0 << 8 | Int($1) }, text.count, "the trailer's size")
        XCTAssertLessThan(zipped.count, text.count / 5)
        XCTAssertEqual(try gunzip(zipped), text)
    }

    func testNothingIsStillAGzipMember() throws {
        let zipped = try Gzip.compress(Data())

        XCTAssertEqual(Array(zipped.prefix(2)), [0x1f, 0x8b])
        XCTAssertEqual(zipped.count, 20)
    }
}
