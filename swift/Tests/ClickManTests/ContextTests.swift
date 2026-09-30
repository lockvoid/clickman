import Foundation
import XCTest
@testable import ClickMan

final class ContextTests: StoreTestCase {
    func testTheContextNamesTheLibraryTheDeviceAndTheSystem() {
        let context = Context.current(bundle: .main)

        XCTAssertEqual(context["library"], .object(["name": .string("clickman-swift"), "version": .string(ClickMan.version)]))
        XCTAssertEqual(context["device"]?["manufacturer"], .string("Apple"))
        XCTAssertNotNil(context["device"]?["model"]?.string)
        XCTAssertNotNil(context["os"]?["version"]?.string)
        XCTAssertEqual(context["locale"], .string(Locale.current.identifier(.bcp47)))
        XCTAssertEqual(context["timezone"], .string(TimeZone.current.identifier))
    }

    func testTheAppComesFromTheBundle() throws {
        let bundle = try makeBundle([
            "CFBundleIdentifier": "com.example.app", "CFBundleName": "Example",
            "CFBundleShortVersionString": "1.40", "CFBundleVersion": "140",
        ])

        XCTAssertEqual(Context.current(bundle: bundle)["app"], .object([
            "name": .string("Example"), "version": .string("1.40"), "build": .string("140"), "namespace": .string("com.example.app"),
        ]))
    }
}
