#if os(macOS)
import AppKit

/// The Mac app delegate, installed with `@NSApplicationDelegateAdaptor`. The
/// iOS one is `AppDelegate`.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Quits the app when its mailbox window closes, Settings window open or not
    /// (`MacMainWindowCloseObserver`).
    private var mainWindowCloseObserver: MacMainWindowCloseObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Not in the unit-test host: the tests end it, and nothing there may quit it first.
        guard !RuntimeEnvironment.isRunningUnitTests else { return }
        let observer = MacMainWindowCloseObserver()
        observer.start()
        mainWindowCloseObserver = observer
    }

    /// Holds the quit while a send is between reservation and outcome, for at
    /// most `AppLifecyclePolicy.outstandingSendTerminationTimeout`. Nothing is
    /// cancelled or resent either way (`OutboundSendTerminationWait`).
    ///
    /// While the reply is pending AppKit runs the main run loop in
    /// `NSModalPanelRunLoopMode`, one of the common modes that drain the main
    /// queue, so main-actor work, the sends' own included, keeps running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let outboundTaskRegistry = OutboundTaskRegistry.shared
        switch AppLifecyclePolicy.terminationDecision(
            hasOutstandingSends: outboundTaskRegistry.hasOutstandingSends
        ) {
        case .terminateNow:
            return .terminateNow
        case .terminateAfterOutstandingSends(let timeout):
            Log.info("Quit waiting for sends in flight", category: .message)
            Task { @MainActor in
                let outcome = await OutboundSendTerminationWait.waitForOutstandingSends(
                    in: outboundTaskRegistry,
                    timeout: timeout,
                    clock: SystemSyncClock()
                )
                if outcome == .timedOut {
                    Log.warning("Quitting with a send still in flight", category: .message)
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}
#endif
