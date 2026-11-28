#if os(iOS)
import UIKit
#elseif os(macOS)
import Foundation
#endif

/// Delivers the app's entry into the background and its return on the main actor:
/// `UIApplication.didEnterBackgroundNotification` and `willEnterForegroundNotification` on iOS. On
/// the Mac it delivers nothing: a Mac app in the background is still on screen, and its pool is
/// released when its chat closes and under memory pressure instead
/// (`FullEmailWebViewManager.releaseIdleWebViews`).
///
/// `@unchecked Sendable`: `start` runs on the main actor, and `stop` from `start` or the owner's
/// teardown, after which nothing else touches it.
final class AppBackgroundEventSource: @unchecked Sendable {
    #if os(iOS)
    private let notificationCenter: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    /// `notificationCenter` is a seam for tests, which post to their own center: a background
    /// notification posted to the default center would reach every observer in the test host.
    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }
    #elseif os(macOS)
    init() {}
    #endif

    /// Calls `onBackground` each time the app enters the background and `onForeground` each time
    /// it is about to return, until `stop()`. Calling it again replaces the earlier handlers.
    @MainActor
    func start(
        onBackground: @escaping @MainActor () -> Void,
        onForeground: @escaping @MainActor () -> Void = {}
    ) {
        stop()
        #if os(iOS)
        observers = [
            notificationCenter.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    onBackground()
                }
            },
            notificationCenter.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    onForeground()
                }
            }
        ]
        #endif
    }

    func stop() {
        #if os(iOS)
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers = []
        #endif
    }

    deinit {
        stop()
    }
}
