#if os(iOS)
import UIKit
#elseif os(macOS)
import Foundation
#endif

/// Delivers the system's low-memory signal on the main actor:
/// `UIApplication.didReceiveMemoryWarningNotification` on iOS, and on the Mac,
/// which has no memory-warning notification, a
/// `DispatchSource.makeMemoryPressureSource` for the `.warning` and
/// `.critical` levels (not `.normal`, which is the all-clear).
///
/// `@unchecked Sendable`: `start` runs on the main actor, and `stop` from
/// `start` or the owner's teardown, after which nothing else touches it.
final class MemoryPressureEventSource: @unchecked Sendable {
    #if os(iOS)
    private let notificationCenter: NotificationCenter
    private var observer: (any NSObjectProtocol)?

    /// `notificationCenter` is a seam for tests, which post to their own
    /// center: a memory warning posted to the default center would reach
    /// every shared cache in the test host.
    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }
    #elseif os(macOS)
    private var source: (any DispatchSourceMemoryPressure)?

    init() {}
    #endif

    /// Calls `onPressure` for every low-memory signal until `stop()`. Calling
    /// it again replaces the earlier handler instead of adding a second one.
    @MainActor
    func start(onPressure: @escaping @MainActor () -> Void) {
        stop()
        #if os(iOS)
        observer = notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                onPressure()
            }
        }
        #elseif os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated {
                onPressure()
            }
        }
        source.activate()
        self.source = source
        #endif
    }

    func stop() {
        #if os(iOS)
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        #elseif os(macOS)
        source?.cancel()
        source = nil
        #endif
    }

    deinit {
        stop()
    }
}
