import Foundation

/// The standard context of docs/PROTOCOL.md: app, device, os, library,
/// locale and timezone.
enum Context {
    static func current(bundle: Bundle = .main) -> [String: Any] {
        let info = bundle.infoDictionary ?? [:]
        let version = ProcessInfo.processInfo.operatingSystemVersion

        var app: [String: Any] = [:]
        app["name"] = info["CFBundleDisplayName"] ?? info["CFBundleName"]
        app["version"] = info["CFBundleShortVersionString"]
        app["build"] = info["CFBundleVersion"]
        app["namespace"] = bundle.bundleIdentifier

        return [
            "app": app,
            "device": ["manufacturer": "Apple", "model": model, "type": deviceType],
            "os": ["name": osName, "version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"],
            "library": ["name": "clickman-swift", "version": ClickMan.version],
            "locale": Locale.current.identifier(.bcp47),
            "timezone": TimeZone.current.identifier,
        ]
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
