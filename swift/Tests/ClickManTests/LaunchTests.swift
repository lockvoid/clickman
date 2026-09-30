import Foundation
import XCTest
@testable import ClickMan

final class LaunchTests: StoreTestCase {
    func testABundleNamesTheVersionAndTheBuild() throws {
        let bundle = try makeBundle(["CFBundleShortVersionString": "1.40", "CFBundleVersion": "140"])

        XCTAssertEqual(Launch(bundle: bundle), Launch(version: "1.40", build: "140"))
    }

    func testABundleWithoutAVersionLaunchesAsUnknown() throws {
        let bundle = try makeBundle(["CFBundleIdentifier": "com.example.tool"])

        XCTAssertEqual(Launch(bundle: bundle), Launch(version: "unknown", build: "unknown"))
    }
}
