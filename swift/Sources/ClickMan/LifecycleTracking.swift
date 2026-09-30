import Foundation
import os

/// The app's lifecycle as events: `app_backgrounded` when it leaves the
/// foreground, `app_opened` when it comes back. The first entry into the
/// foreground is the launch, which the launch events already report; a
/// scene-based app is told `willEnterForeground` for it all the same.
final class LifecycleTracking: Sendable {
    private enum Place {
        case foreground
        case background
    }

    private let tracker: Tracker
    private let tracksLifecycle: Bool
    private let place = OSAllocatedUnfairLock(initialState: Place.foreground)

    init(tracker: Tracker, tracksLifecycle: Bool) {
        self.tracker = tracker
        self.tracksLifecycle = tracksLifecycle
    }

    func didEnterBackground() {
        place.withLock { $0 = .background }
        if tracksLifecycle {
            tracker.track(.appBackgrounded)
        }
    }

    func willEnterForeground() {
        let left = place.withLock { place in
            defer { place = .foreground }
            return place
        }
        guard left == .background else {
            return
        }

        tracker.refreshContext()
        if tracksLifecycle {
            tracker.track(.appOpened(fromBackground: true))
        }
    }
}
