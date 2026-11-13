#if os(macOS)
import AppKit

/// Quits the Mac app when its mailbox window closes (`MacMainWindowPolicy`), so an open
/// Settings window cannot keep it running, and syncing, with no mailbox on screen.
///
/// The quit is asked for from the run loop, never from a block on the main queue or a
/// main-actor task. `MacAppDelegate.applicationShouldTerminate` holds a quit for a send in
/// flight and answers from a main-actor task, and AppKit waits for that answer inside
/// `terminate(_:)`. Called from a block on the main queue, `terminate(_:)` waits inside that
/// block, the queue cannot run the task that answers, and the app hangs with its window gone:
/// measured in a stand-in program on macOS 27.2 (2026-11-13), which never quit. Asked from the
/// run loop, the same program quit when the answer came, and `applicationShouldTerminate` was
/// called once in every case, including the ones where SwiftUI's own quit follows the same
/// close.
///
/// HONEST SCOPE: measured in that program, not in the app. Nothing has closed the app's window
/// with its Settings window open.
@MainActor
final class MacMainWindowCloseObserver {
    private let notificationCenter: NotificationCenter
    private let quit: @MainActor () -> Void
    private var observation: NSObjectProtocol?

    /// - Parameters:
    ///   - notificationCenter: Where windows post that they will close. The tests give their
    ///     own, so nothing they post reaches the app's observer.
    ///   - quit: Asks the app to quit. The tests record the call: the real one would end the
    ///     test host.
    init(
        notificationCenter: NotificationCenter = .default,
        quit: @escaping @MainActor () -> Void = MacMainWindowCloseObserver.quitFromRunLoop
    ) {
        self.notificationCenter = notificationCenter
        self.quit = quit
    }

    /// Starts watching. Calling it again changes nothing.
    func start() {
        guard observation == nil else { return }
        let quit = quit
        // `queue: nil`: the block runs where the notification is posted, which for a window
        // closing is the main thread.
        observation = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: nil
        ) { notification in
            let identifier = (notification.object as? NSWindow)?.identifier?.rawValue
            guard MacMainWindowPolicy.closingQuitsApp(windowIdentifier: identifier) else { return }
            MainActor.assumeIsolated {
                quit()
            }
        }
    }

    func stop() {
        if let observation {
            notificationCenter.removeObserver(observation)
        }
        observation = nil
    }

    /// Asks the app to quit on the run loop's next turn. See the type's comment for why this
    /// is neither `DispatchQueue.main.async` nor a `Task`.
    static func quitFromRunLoop() {
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}
#endif
