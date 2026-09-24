import ClickManCore
import Foundation
import os

/// The device queue of the Rust core, behind `clickman.h`. The core serializes
/// calls itself, so the handle may be used from any thread.
final class Queue: @unchecked Sendable {
    private let handle: OpaquePointer
    private let logger: Logger

    init(storage: URL, configuration: [String: Int], logger: Logger) throws {
        try FileManager.default.createDirectory(
            at: storage.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let config = String(decoding: try JSONSerialization.data(withJSONObject: configuration), as: UTF8.self)

        guard let handle = clickman_open(storage.path, config) else {
            throw ClickManError.storage(Self.lastError)
        }
        self.handle = handle
        self.logger = logger
    }

    deinit {
        clickman_close(handle)
    }

    func identify(_ externalId: String) {
        check(clickman_identify(handle, externalId), "identify")
    }

    func reset() {
        check(clickman_reset(handle), "reset")
    }

    func setContext(_ json: String) {
        check(clickman_set_context(handle, json), "set the context")
    }

    func setTraits(_ json: String) {
        check(clickman_set_traits(handle, json), "set the traits")
    }

    func appLaunched(version: String, build: String, at date: Date) {
        check(clickman_app_launched(handle, version, build, Self.milliseconds(date)), "record the launch")
    }

    func track(_ event: String, properties json: String, at timestamp: Date) {
        check(clickman_track(handle, event, json, Self.milliseconds(timestamp)), "track \(event)")
    }

    func takeBatch(now: Date, force: Bool) -> Batch? {
        var batch = clickman_batch()
        let taken = clickman_take_batch(handle, Self.milliseconds(now), force, &batch)
        guard taken == 1 else {
            check(taken, "take a batch")
            return nil
        }
        defer { clickman_buf_free(batch.body) }

        return Batch(id: batch.id, events: Int(batch.events), body: Data(bytes: batch.body.ptr, count: batch.body.len))
    }

    func complete(_ batch: Batch, status: Int, retryAfter: TimeInterval?, now: Date) {
        let retryAfter = retryAfter.map { Int64($0 * 1000) } ?? -1
        check(
            clickman_complete_batch(handle, batch.id, Int32(clamping: status), retryAfter, Self.milliseconds(now)),
            "complete batch \(batch.id)"
        )
    }

    var pending: Int {
        Int(clickman_pending(handle))
    }

    private func check(_ result: Int32, _ action: String) {
        if result < 0 {
            logger.error("ClickMan could not \(action, privacy: .public): \(Self.lastError, privacy: .public)")
        }
    }

    private static var lastError: String {
        String(cString: clickman_last_error())
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

struct Batch: Sendable {
    let id: UInt64
    let events: Int
    let body: Data
}
