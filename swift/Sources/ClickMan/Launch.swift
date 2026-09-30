import Foundation

/// The version and build of one launch of the app.
struct Launch: Equatable, Sendable {
    let version: String
    let build: String

    /// The launch `bundle` names; a bundle without a version, such as a
    /// command-line tool's, launches as `unknown`.
    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        build = info["CFBundleVersion"] as? String ?? "unknown"
    }

    init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    /// The events this launch records after `last`, the launch the store
    /// remembers, nil before the first (lifecycle.json).
    func events(after last: Launch?) -> [Event] {
        [change(since: last), .appOpened(fromBackground: false)].compactMap { $0 }
    }

    private func change(since last: Launch?) -> Event? {
        guard let last else {
            return Event(name: "app_installed", properties: versionAndBuild)
        }
        guard last != self else {
            return nil
        }
        let previous: [String: JSONValue] = ["previous_version": .string(last.version), "previous_build": .string(last.build)]
        return Event(name: "app_updated", properties: versionAndBuild.merging(previous) { _, previous in previous })
    }

    private var versionAndBuild: [String: JSONValue] {
        ["version": .string(version), "build": .string(build)]
    }
}
