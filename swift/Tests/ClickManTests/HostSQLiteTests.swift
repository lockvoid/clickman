import Foundation
import SQLite3
import XCTest
@testable import ClickMan

/// The app around ClickMan uses SQLite itself (GRDB, Core Data). A core that
/// brought a SQLite of its own would shadow the system library for the whole
/// app, and a connection opened by one copy and handed to the other crashes.
final class HostSQLiteTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "clickman-host-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        StubServer.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAHostCallsTheSystemSQLite() {
        XCTAssertEqual(Self.hostSQLiteImage(), "libsqlite3.dylib")
    }

    func testAHostConnectionTakesAWALSnapshotBesideClickMan() throws {
        // With a second SQLite in the app, `sqlite3_snapshot_get` below spins or crashes instead of failing.
        guard Self.hostSQLiteImage() == "libsqlite3.dylib" else { return XCTFail("the host does not call the system SQLite") }

        var configuration = ClickMan.Configuration(endpoint: URL(string: "https://ingest.test")!, writeKey: "ios-key")
        configuration.storage = directory.appending(path: "queue.sqlite")
        configuration.session = StubServer.session()
        configuration.pollInterval = .seconds(3600)
        configuration.observesSystem = false
        configuration.tracksLifecycle = false
        let clickMan = try ClickMan(configuration: configuration)
        clickMan.track("app_opened")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appending(path: "host.sqlite").path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode = WAL; CREATE TABLE rows (id); INSERT INTO rows VALUES (1); BEGIN; SELECT * FROM rows;", nil, nil, nil), SQLITE_OK)

        var snapshot: UnsafeMutablePointer<sqlite3_snapshot>?
        XCTAssertEqual(sqlite3_snapshot_get(db, "main", &snapshot), SQLITE_OK)
        sqlite3_snapshot_free(snapshot)
    }

    /// The file `sqlite3_open_v2` resolves to in this process.
    private static func hostSQLiteImage() -> String? {
        let open: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, Int32, UnsafePointer<CChar>?) -> Int32 = sqlite3_open_v2
        var image = Dl_info()
        guard dladdr(unsafeBitCast(open, to: UnsafeRawPointer.self), &image) != 0, let file = image.dli_fname else { return nil }
        return URL(fileURLWithPath: String(cString: file)).lastPathComponent
    }
}
