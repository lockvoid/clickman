import Foundation
import GRDB

/// The device queue: one SQLite file with the events waiting to be sent and the
/// identity they are tracked under (protocol/queue.sql).
final class Queue: Sendable {
    private let database: DatabaseQueue
    private let maxQueue: Int

    /// Opens the store at `path`: a new store is created, one the 0.1 Rust core
    /// wrote is adopted, and one a newer ClickMan wrote is refused.
    init(path: URL, maxQueue: Int) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = GRDB.Configuration()
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        database = try DatabaseQueue(path: path.path(percentEncoded: false), configuration: configuration)
        self.maxQueue = maxQueue
        try database.write(Self.prepare)
    }

    /// Runs `work` in one write transaction.
    func write<T>(_ work: (QueueTransaction) throws -> T) throws -> T {
        try database.write { db in
            try work(QueueTransaction(db: db, maxQueue: maxQueue))
        }
    }

    /// How many events wait and since when; nil when none do.
    func waiting() throws -> Waiting? {
        try database.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT count(*) AS count, min(created_at) AS oldest FROM events")!
            let oldest: Int64? = row["oldest"]
            return oldest.map { Waiting(count: row["count"], oldestCreatedAt: Date(unixMilliseconds: $0)) }
        }
    }

    /// The oldest `limit` events, oldest first.
    func oldest(_ limit: Int) throws -> [QueuedEvent] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT seq, body FROM events ORDER BY seq LIMIT ?", arguments: [limit])
                .map { QueuedEvent(seq: $0["seq"], body: $0["body"]) }
        }
    }

    /// Deletes the events created before `cutoff`, unsent.
    func purge(createdBefore cutoff: Date) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM events WHERE created_at < ?", arguments: [cutoff.unixMilliseconds])
        }
    }

    /// Deletes the events through `seq`, the last of a batch that left the queue.
    func delete(through seq: Int64) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM events WHERE seq <= ?", arguments: [seq])
        }
    }

    /// The events on the device, in flight or waiting.
    func count() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM events")!
        }
    }

    private static func prepare(_ db: Database) throws {
        let format = try Int.fetchOne(db, sql: "PRAGMA user_version")!
        guard format <= QueueSchema.format else {
            throw ClickManError.storage("The queue was written by a newer ClickMan: format \(format), this one reads \(QueueSchema.format)")
        }
        guard format == 0 else {
            return
        }
        try db.execute(sql: QueueSchema.create)
        if try db.tableExists("state") {
            try db.execute(sql: QueueSchema.upgrade)
        }
        try db.execute(sql: "PRAGMA user_version = \(QueueSchema.format)")
    }
}

/// An event in the queue: its place and its JSON.
struct QueuedEvent: Equatable, Sendable {
    let seq: Int64
    let body: String
}

/// How many events wait, and when the oldest was created.
struct Waiting: Equatable, Sendable {
    let count: Int
    let oldestCreatedAt: Date
}

/// The queue inside one write transaction.
struct QueueTransaction {
    let db: Database
    let maxQueue: Int

    func identity() throws -> Identity {
        let row = try Row.fetchOne(db, sql: "SELECT external_id, traits, app_version, app_build FROM identity WHERE id = 1")!
        return Identity(
            externalId: row["external_id"],
            traits: try JSONValue.object(parsing: row["traits"]),
            lastLaunch: Self.launch(version: row["app_version"], build: row["app_build"])
        )
    }

    /// Stores `body`, then drops the oldest events beyond the queue's limit.
    func append(_ body: String, createdAt: Date) throws {
        try db.execute(
            sql: "INSERT INTO events (created_at, body) VALUES (?, ?)",
            arguments: [createdAt.unixMilliseconds, body]
        )
        try db.execute(
            sql: "DELETE FROM events WHERE seq IN (SELECT seq FROM events ORDER BY seq DESC LIMIT -1 OFFSET ?)",
            arguments: [maxQueue]
        )
    }

    func setExternalId(_ externalId: String) throws {
        try db.execute(sql: "UPDATE identity SET external_id = ? WHERE id = 1", arguments: [externalId])
    }

    func setTraits(_ traits: [String: JSONValue]) throws {
        try db.execute(sql: "UPDATE identity SET traits = ? WHERE id = 1", arguments: [JSONValue.object(traits).json()])
    }

    func setLastLaunch(_ launch: Launch) throws {
        try db.execute(
            sql: "UPDATE identity SET app_version = ?, app_build = ? WHERE id = 1",
            arguments: [launch.version, launch.build]
        )
    }

    /// Later events are anonymous and carry no traits.
    func reset() throws {
        try db.execute(sql: "UPDATE identity SET external_id = '*', traits = '{}' WHERE id = 1")
    }

    private static func launch(version: String?, build: String?) -> Launch? {
        switch (version, build) {
        case let (version?, build?): Launch(version: version, build: build)
        default: nil
        }
    }
}
