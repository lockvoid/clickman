import Foundation

/// The standard context of docs/PROTOCOL.md: app, device, os, library, locale
/// and timezone. It lives in memory and is never stored.
enum Context {
    static func current(bundle: Bundle) -> [String: JSONValue] {
        [
            "app": .object(app(bundle)),
            "device": .object(["manufacturer": .string("Apple"), "model": .string(model), "type": .string(deviceType)]),
            "os": .object(["name": .string(osName), "version": .string(osVersion)]),
            "library": .object(["name": .string("clickman-swift"), "version": .string(ClickMan.version)]),
            "locale": .string(Locale.current.identifier(.bcp47)),
            "timezone": .string(TimeZone.current.identifier),
        ]
    }

    private static func app(_ bundle: Bundle) -> [String: JSONValue] {
        let info = bundle.infoDictionary ?? [:]
        let fields: [String: String?] = [
            "name": (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
            "version": info["CFBundleShortVersionString"] as? String,
            "build": info["CFBundleVersion"] as? String,
            "namespace": bundle.bundleIdentifier,
        ]
        return fields.compactMapValues { $0.map(JSONValue.string) }
    }

    private static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static var osName: String {
        #if os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #elseif os(tvOS)
        "tvOS"
        #elseif os(watchOS)
        "watchOS"
        #elseif os(visionOS)
        "visionOS"
        #else
        "unknown"
        #endif
    }

    private static var deviceType: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }
}
