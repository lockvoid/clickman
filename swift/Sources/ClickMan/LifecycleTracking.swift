import Foundation
import os

/// The app's lifecycle as events: `app_backgrounded` when it leaves the
/// foreground, `app_opened` when it comes back. The first entry into the
/// foreground is the launch, which `appLaunched` has already reported; a
/// scene-based app is told `willEnterForeground` for it all the same.
final class LifecycleTracking: Sendable {
    private let queue: Queue
    private let bundle: Bundle
    private let tracksLifecycle: Bool
    private let backgrounded = OSAllocatedUnfairLock(initialState: false)

    init(queue: Queue, bundle: Bundle, tracksLifecycle: Bool) {
        self.queue = queue
        self.bundle = bundle
        self.tracksLifecycle = tracksLifecycle
    }

    func didEnterBackground() {
        backgrounded.withLock { $0 = true }
        if tracksLifecycle {
            queue.track("app_backgrounded", properties: "{}", at: Date())
        }
    }

    func willEnterForeground() {
        let returning = backgrounded.withLock { backgrounded in
            defer { backgrounded = false }
            return backgrounded
        }
        guard returning else {
            return
        }

        ClickMan.refreshContext(of: queue, bundle: bundle)
        if tracksLifecycle {
            queue.track("app_opened", properties: #"{"from_background":true}"#, at: Date())
        }
    }
}
