import Foundation
import GRDB
import os
import XCTest
@testable import ClickMan

/// The shared fixtures in protocol/fixtures, read where they are.
enum Fixture {
    private static let directory = (0..<4)
        .reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        .appending(path: "protocol/fixtures")

    /// Every case of `name`, decoded.
    static func cases<Case: Decodable>(_ name: String, as type: Case.Type) throws -> [Case] {
        let cases = try JSONDecoder().decode(FixtureFile<Case>.self, from: Data(contentsOf: directory.appending(path: name))).cases
        XCTAssertFalse(cases.isEmpty, "\(name) holds no cases")
        return cases
    }

    /// Every case of `name` as JSON, for the fixtures whose values are any JSON.
    static func cases(_ name: String) throws -> [JSONValue] {
        let file = try JSONValue(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: name))))
        let cases = try XCTUnwrap(file["cases"]?.array, "\(name) holds no cases")
        XCTAssertFalse(cases.isEmpty, "\(name) holds no cases")
        return cases
    }
}

private struct FixtureFile<Case: Decodable>: Decodable {
    let cases: [Case]
}

/// A test with a queue file of its own in a fresh temporary directory, and a
/// stub server answering 202 until told otherwise.
class StoreTestCase: XCTestCase {
    private(set) var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory
            .appending(path: "clickman-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "queue.sqlite")
        StubServer.reset()
    }

    override func tearDownWithError() throws {
        let directory = storage.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Reads the store with a connection of the test's own.
    func inspect<T>(_ read: (Database) throws -> T) throws -> T {
        try connection().read(read)
    }

    /// Writes the store with a connection of the test's own, behind ClickMan's back.
    func tamper(_ write: (Database) throws -> Void) throws {
        try connection().write(write)
    }

    /// A connection that waits, as ClickMan's does, while one of an instance still closing holds the file.
    private func connection() throws -> DatabaseQueue {
        var configuration = GRDB.Configuration()
        configuration.busyMode = .timeout(5)
        return try DatabaseQueue(path: storage.path(percentEncoded: false), configuration: configuration)
    }

    /// A store as the 0.1 Rust core left it: format 0, the actor, traits and last
    /// launch in `state` beside its lease and retry keys, and one event leased to a batch.
    func writeOldCoreStore(body: String) throws {
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try DatabaseQueue(path: storage.path(percentEncoded: false))
        try database.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, created_at INTEGER NOT NULL, body TEXT NOT NULL, batch_id INTEGER);
                CREATE INDEX events_batch ON events (batch_id);
                CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO state (key, value) VALUES
                    ('external_id', 'user_7'), ('traits', '{"plan":"pro"}'), ('app_version', '1.39'), ('app_build', '139'),
                    ('lease_batch_id', '1'), ('lease_until', '9999999999999'), ('next_batch_id', '2'),
                    ('attempts', '6'), ('next_attempt_at', '9999999999999');
                """)
            try db.execute(sql: "INSERT INTO events (created_at, body, batch_id) VALUES (?, ?, 1)", arguments: [Date().unixMilliseconds, body])
        }
    }

    /// An empty store stamped with `format`.
    func writeStore(format: Int) throws {
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DatabaseQueue(path: storage.path(percentEncoded: false)).write { db in
            try db.execute(sql: "PRAGMA user_version = \(format)")
        }
    }

    /// A bundle whose Info.plist holds `info`, in the test's directory.
    func makeBundle(_ info: [String: String]) throws -> Bundle {
        let directory = storage.deletingLastPathComponent().appending(path: "App-\(UUID().uuidString).bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appending(path: "Info.plist"))
        return try XCTUnwrap(Bundle(url: directory))
    }
}

extension ClickMan.Configuration {
    /// The stub server, no system observers, a poll that never comes back and no lifecycle events.
    static func test(storage: URL) -> ClickMan.Configuration {
        var configuration = ClickMan.Configuration(endpoint: URL(string: "https://ingest.test")!, writeKey: "ios-key")
        configuration.storage = storage
        configuration.session = StubServer.session()
        configuration.pollInterval = .seconds(3600)
        configuration.observesSystem = false
        configuration.tracksLifecycle = false
        return configuration
    }
}

/// A clock the test moves by hand, starting on a whole millisecond.
final class TestClock: Sendable {
    private let date = OSAllocatedUnfairLock(initialState: Date(unixMilliseconds: 1_727_697_600_000))

    var now: Date {
        date.withLock { $0 }
    }

    var reading: @Sendable () -> Date {
        { self.now }
    }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    var array: [JSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }

    var object: [String: JSONValue]? {
        guard case .object(let members) = self else { return nil }
        return members
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

/// The Unix milliseconds in the first 48 bits of a UUID string.
func uuidMilliseconds(_ uuid: String) throws -> Int64 {
    let bytes = withUnsafeBytes(of: try XCTUnwrap(UUID(uuidString: uuid)).uuid) { Array($0) }
    return bytes.prefix(6).reduce(Int64(0)) { $0 << 8 | Int64($1) }
}
