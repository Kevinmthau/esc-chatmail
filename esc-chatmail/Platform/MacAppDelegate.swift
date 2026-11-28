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

    /// Holds the quit while a send is between reservation and outcome, or a
    /// reply-draft write has not finished, for at most
    /// `AppLifecyclePolicy.outstandingWorkTerminationTimeout` for both
    /// together. Nothing is cancelled or resent either way, and no draft is
    /// written outside a composer's own save (`AppTerminationWait`).
    ///
    /// First it has each on-screen composer start the save it still owes
    /// (`ChatReplyComposerDirectory.flushPresentedDraftsForTermination`): the
    /// one its 350 ms debounce has not made yet, one that failed, or one for
    /// files still importing. So the decision counts the words typed just
    /// before Cmd-Q or the window's close. The saves wait for the
    /// cleanup-sensitive gate like any other.
    ///
    /// While the reply is pending AppKit runs the main run loop in
    /// `NSModalPanelRunLoopMode`, one of the common modes that drain the main
    /// queue, so main-actor work, the sends' and the draft saves' included,
    /// keeps running. The reply comes from one main-actor task, once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let outboundTaskRegistry = OutboundTaskRegistry.shared
        let composerDirectory = ChatReplyComposerDirectory.shared
        composerDirectory.flushPresentedDraftsForTermination()
        let draftWriteTracker = composerDirectory.draftWriteTracker
        switch AppLifecyclePolicy.terminationDecision(
            hasOutstandingSends: outboundTaskRegistry.hasOutstandingSends,
            hasOutstandingDraftWrites: draftWriteTracker.hasOutstandingWrites
        ) {
        case .terminateNow:
            return .terminateNow
        case .terminateAfterOutstandingWork(let timeout):
            Log.info("Quit waiting for sends in flight or reply drafts being saved", category: .message)
            Task { @MainActor in
                let outcome = await AppTerminationWait.waitForOutstandingWork(
                    sends: outboundTaskRegistry,
                    draftWrites: draftWriteTracker,
                    timeout: timeout,
                    clock: SystemSyncClock()
                )
                if case .timedOut(let sendsOutstanding, let draftWritesOutstanding) = outcome {
                    if sendsOutstanding {
                        Log.warning("Quitting with a send still in flight", category: .message)
                    }
                    if draftWritesOutstanding {
                        Log.warning("Quitting with a reply draft not yet saved", category: .message)
                    }
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}
#endif
