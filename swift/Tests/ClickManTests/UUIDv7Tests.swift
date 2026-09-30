import Foundation
import XCTest
@testable import ClickMan

final class UUIDv7Tests: XCTestCase {
    func testTheIdCarriesTheMillisecondsTheVersionAndTheVariant() throws {
        let id = UUIDv7.string(at: Date(unixMilliseconds: 1_727_697_600_123))
        let bytes = withUnsafeBytes(of: try XCTUnwrap(UUID(uuidString: id)).uuid) { Array($0) }

        XCTAssertEqual(try uuidMilliseconds(id), 1_727_697_600_123)
        XCTAssertEqual(bytes[6] >> 4, 7)
        XCTAssertEqual(bytes[8] >> 6, 0b10)
    }

    func testTheIdIsLowercaseInTheCanonicalForm() {
        let id = UUIDv7.string(at: Date())
        XCTAssertEqual(id, id.lowercased())
        XCTAssertEqual(id.split(separator: "-").map(\.count), [8, 4, 4, 4, 12])
    }

    func testTheRestIsRandom() {
        let date = Date()
        XCTAssertEqual(Set((0..<100).map { _ in UUIDv7.string(at: date) }).count, 100)
    }
}
