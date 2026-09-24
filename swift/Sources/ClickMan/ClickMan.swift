import Foundation
import Network
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

    // Every stored property is set once in init and never mutated, which is
    // what makes the unchecked Sendable conformance hold.
    private let queue: Queue
    private let sender: Sender
    private let logger = Logger(subsystem: "com.lockvoid.clickman", category: "ClickMan")
    private let poller: Task<Void, Never>
    private let network: NWPathMonitor?
    private let observers: [NSObjectProtocol]

    public init(configuration: Configuration) throws {
        let storage = try configuration.storage ?? Self.defaultStorage()
        let queue = try Queue(
            storage: storage,
            configuration: [
                "flushAt": configuration.flushAt,
                "flushIntervalMs": Int(configuration.flushInterval / .milliseconds(1)),
                "maxQueue": configuration.maxQueue,
            ],
            logger: logger
        )
        let sender = Sender(
            queue: queue,
            endpoint: configuration.endpoint,
            writeKey: configuration.writeKey,
            session: configuration.session,
            logger: logger
        )
        self.queue = queue
        self.sender = sender

        let interval = configuration.pollInterval
        poller = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await sender.drain(force: false)
                try? await Task.sleep(for: interval)
            }
        }

        if configuration.observesSystem {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied {
                    Task { await sender.drain(force: true) }
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.lockvoid.clickman.network", qos: .utility))
            network = monitor
            observers = Self.observeApplication(
                sender: sender,
                queue: queue,
                bundle: configuration.bundle,
                tracksLifecycle: configuration.tracksLifecycle,
                logger: logger
            )
        } else {
            network = nil
            observers = []
        }

        Self.refreshContext(of: queue, bundle: configuration.bundle)
        if configuration.tracksLifecycle {
            let info = configuration.bundle.infoDictionary ?? [:]
            queue.appLaunched(
                version: info["CFBundleShortVersionString"] as? String ?? "unknown",
                build: info["CFBundleVersion"] as? String ?? "unknown",
                at: Date()
            )
        }
    }

    deinit {
        poller.cancel()
        network?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Queues an event. Properties are JSON values; `Date`, `URL` and `UUID`
    /// are sent as strings. An event that cannot be encoded is dropped and
    /// logged, never thrown.
    public func track(_ event: String, properties: [String: Any] = [:]) {
        guard let json = Self.encode(properties) else {
            logger.error("ClickMan dropped \(event, privacy: .public): its properties are not JSON")
            return
        }
        queue.track(event, properties: json, at: Date())
    }

    /// Makes the host's user id the actor of every event tracked from now on.
    public func identify(_ externalId: String) {
        queue.identify(externalId)
    }

    /// Merges traits of the actor into `context.traits` of every event tracked
    /// from now on, e.g. `["plan": "pro"]`; nil removes a trait. The traits
    /// are kept across launches until `reset()`.
    public func setTraits(_ traits: [String: Any?]) {
        guard let json = Self.encode(traits.mapValues { $0 ?? NSNull() }) else {
            logger.error("ClickMan ignored traits that are not JSON")
            return
        }
        queue.setTraits(json)
    }

    /// Makes events tracked from now on anonymous and forgets the traits, e.g.
    /// after signing out.
    public func reset() {
        queue.reset()
    }

    /// Sends everything waiting, returning once the queue is empty or a send
    /// has failed and waits for its retry.
    public func flush() async {
        await sender.drain(force: true)
    }

    /// Events on the device, in flight or waiting.
    public var pendingEvents: Int {
        queue.pending
    }

    static func refreshContext(of queue: Queue, bundle: Bundle) {
        if let json = encode(Context.current(bundle: bundle)) {
            queue.setContext(json)
        }
    }

    private static func observeApplication(
        sender: Sender,
        queue: Queue,
        bundle: Bundle,
        tracksLifecycle: Bool,
        logger: Logger
    ) -> [NSObjectProtocol] {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                if tracksLifecycle {
                    queue.track("app_backgrounded", properties: "{}", at: Date())
                }
                MainActor.assumeIsolated {
                    BackgroundFlush().start(sender: sender, logger: logger)
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                refreshContext(of: queue, bundle: bundle)
                if tracksLifecycle {
                    queue.track("app_opened", properties: #"{"from_background":true}"#, at: Date())
                }
            },
        ]
        #else
        return []
        #endif
    }

    static func encode(_ object: [String: Any]) -> String? {
        let converted = object.mapValues(jsonValue)
        guard JSONSerialization.isValidJSONObject(converted),
              let data = try? JSONSerialization.data(withJSONObject: converted)
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonValue(_ value: Any) -> Any {
        switch value {
        case let date as Date:
            return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        case let url as URL:
            return url.absoluteString
        case let uuid as UUID:
            return uuid.uuidString
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonValue)
        case let array as [Any]:
            return array.map(jsonValue)
        default:
            return value
        }
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
        try? directory.setResourceValues(values)
        return directory.appending(path: "queue.sqlite")
    }
}

#if canImport(UIKit)
/// Keeps the app alive long enough to send what is waiting when it leaves the
/// foreground; iOS allows roughly thirty seconds.
@MainActor
private final class BackgroundFlush {
    private var task = UIBackgroundTaskIdentifier.invalid

    func start(sender: Sender, logger: Logger) {
        task = UIApplication.shared.beginBackgroundTask(withName: "ClickMan flush") {
            logger.info("ClickMan ran out of background time; the rest is sent on the next launch")
            self.end()
        }
        Task {
            await sender.drain(force: true)
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
