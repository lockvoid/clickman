import Foundation
import Network
import os

/// Calls back when the network returns: a satisfied path after one that was
/// not. The monitor's first report, at start, is the network as it is.
final class NetworkReturn: Sendable {
    private let monitor = NWPathMonitor()

    init(onReturn: @escaping @Sendable () -> Void) {
        let last = OSAllocatedUnfairLock<NWPath.Status?>(initialState: nil)
        monitor.pathUpdateHandler = { path in
            let current = path.status
            let previous = last.withLock { status in
                defer { status = current }
                return status
            }
            if Self.isReturn(from: previous, to: current) {
                onReturn()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.lockvoid.clickman.network", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    static func isReturn(from previous: NWPath.Status?, to current: NWPath.Status) -> Bool {
        switch (previous, current) {
        case (.unsatisfied?, .satisfied), (.requiresConnection?, .satisfied): true
        default: false
        }
    }
}
