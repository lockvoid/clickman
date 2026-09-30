import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

public enum ClickManError: Error, Equatable {
    case storage(String)
}

/// ClickMan analytics for Apple platforms. Events are queued on the device the
/// moment they are tracked and sent in gzipped batches — when enough are
/// waiting, when the oldest has waited long enough, when the app leaves the
/// foreground and when the network returns. Tracking never blocks on the
/// network and never throws.
public final class ClickMan: @unchecked Sendable {
    public static let version = "0.1.0"

    public struct Configuration: Sendable {
        /// The ingest server, e.g. `https://clickman.example.com`.
        public var endpoint: URL
        /// The write key of this app's source.
        public var writeKey: String
        /// A batch is sent once this many events are waiting.
        public var flushAt = 20
        /// A batch is sent once the oldest waiting event is this old.
        public var flushInterval: Duration = .seconds(30)
        /// The most events kept on the device; the oldest go first.
        public var maxQueue = 10_000
        /// Where the queue lives; Application Support/ClickMan by default.
        public var storage: URL?
        /// Sends `app_installed`, `app_updated`, `app_opened` and
        /// `app_backgrounded` (docs/PROTOCOL.md).
        public var tracksLifecycle = true

        var session = URLSession(configuration: .ephemeral)
        var bundle = Bundle.main
        var pollInterval: Duration = .seconds(5)
        var observesSystem = true

        public init(endpoint: URL, writeKey: String) {
            self.endpoint = endpoint
            self.writeKey = writeKey
        }
    }

    static let logger = Logger(subsystem: "com.lockvoid.clickman", category: "ClickMan")

    // Every stored property is set once in init and never mutated: the unchecked Sendable rests on it.
    private let queue: Queue
    private let tracker: Tracker
    private let sender: Sender
    private let poller: Task<Void, Never>
    private let network: NetworkReturn?
    private let observers: [NSObjectProtocol]
    let lifecycle: LifecycleTracking

    /// Opens the queue and records the launch; throws when the queue cannot be opened.
    public init(configuration: Configuration) throws {
        queue = try Queue(path: configuration.storage ?? Self.defaultStorage(), maxQueue: configuration.maxQueue)
        tracker = Tracker(queue: queue, bundle: configuration.bundle, clock: { Date() }, logger: Self.logger)
        sender = Sender(queue: queue, configuration: configuration, clock: { Date() }, logger: Self.logger)
        lifecycle = LifecycleTracking(tracker: tracker, tracksLifecycle: configuration.tracksLifecycle)
        if configuration.tracksLifecycle {
            tracker.recordLaunch(Launch(bundle: configuration.bundle))
        }
        poller = Self.poll(sender, every: configuration.pollInterval)
        network = configuration.observesSystem ? Self.watchNetwork(sender) : nil
        observers = configuration.observesSystem ? Self.observeApplication(sender: sender, lifecycle: lifecycle) : []
    }

    deinit {
        poller.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Queues an event. Properties are JSON values; `Date`, `URL` and `UUID`
    /// are sent as strings. An event that cannot be stored is dropped and
    /// logged, never thrown.
    public func track(_ event: String, properties: [String: Any] = [:]) {
        let json: [String: JSONValue]
        do {
            json = try JSONValue.object(from: properties)
        } catch {
            Self.logger.error("ClickMan dropped \(event, privacy: .public): its properties are not JSON, \(String(describing: error), privacy: .public)")
            return
        }
        tracker.track(Event(name: event, properties: json))
    }

    /// Makes the host's user id the actor of every event tracked from now on.
    public func identify(_ externalId: String) {
        tracker.identify(externalId)
    }

    /// Merges traits of the actor into `context.traits` of every event tracked
    /// from now on, e.g. `["plan": "pro"]`; nil removes a trait. The traits
    /// are kept across launches until `reset()`.
    public func setTraits(_ traits: [String: Any?]) {
        let changes: [String: JSONValue]
        do {
            changes = try JSONValue.object(from: traits.mapValues { $0 ?? NSNull() })
        } catch {
            Self.logger.error("ClickMan ignored traits that are not JSON: \(String(describing: error), privacy: .public)")
            return
        }
        tracker.setTraits(changes)
    }

    /// Makes events tracked from now on anonymous and forgets the traits, e.g.
    /// after signing out.
    public func reset() {
        tracker.reset()
    }

    /// Sends everything waiting, returning once the queue is empty or a send
    /// has failed and waits for its retry.
    public func flush() async {
        await sender.drain(.everything)
    }

    /// Events on the device, in flight or waiting.
    public var pendingEvents: Int {
        do {
            return try queue.count()
        } catch {
            Self.logger.error("ClickMan could not count the waiting events: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    private static func poll(_ sender: Sender, every interval: Duration) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await sender.drain(.due)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private static func watchNetwork(_ sender: Sender) -> NetworkReturn {
        NetworkReturn {
            Task { await sender.drain(.everything) }
        }
    }

    private static func observeApplication(sender: Sender, lifecycle: LifecycleTracking) -> [NSObjectProtocol] {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                lifecycle.didEnterBackground()
                MainActor.assumeIsolated {
                    BackgroundFlush().start(sender: sender)
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                lifecycle.willEnterForeground()
            },
        ]
        #else
        return []
        #endif
    }

    private static func defaultStorage() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var directory = support.appending(path: "ClickMan", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory.appending(path: "queue.sqlite")
    }
}

#if canImport(UIKit)
/// Keeps the app alive long enough to send what is waiting when it leaves the
/// foreground; iOS allows roughly thirty seconds.
@MainActor
private final class BackgroundFlush {
    private var task = UIBackgroundTaskIdentifier.invalid

    func start(sender: Sender) {
        task = UIApplication.shared.beginBackgroundTask(withName: "ClickMan flush") {
            ClickMan.logger.info("ClickMan ran out of background time; the rest is sent on the next launch")
            self.end()
        }
        Task {
            await sender.drain(.everything)
            self.end()
        }
    }

    private func end() {
        guard task != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
#endif
