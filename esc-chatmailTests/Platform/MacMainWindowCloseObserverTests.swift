#if os(macOS)
import AppKit
import XCTest
@testable import esc_chatmail

/// `MacMainWindowCloseObserver`, with a notification center of its own and a recorded quit.
///
/// HONEST SCOPE: no window is closed here and nothing quits. The tests post the notification
/// a closing window posts, for windows that are never shown, to a center the app's own
/// observer does not watch. That SwiftUI gives the mailbox window the scene's id as its
/// identifier is read here from the test host's own window, which is the app's. That a quit
/// asked for from the run loop goes through with a quit being held was measured in a stand-in
/// program (`MacMainWindowCloseObserver`), not here.
@MainActor
final class MacMainWindowCloseObserverTests: XCTestCase {
    private var center: NotificationCenter!
    private var quitCount = 0
    private var observer: MacMainWindowCloseObserver!

    override func setUp() async throws {
        try await super.setUp()
        center = NotificationCenter()
        quitCount = 0
        observer = MacMainWindowCloseObserver(notificationCenter: center, quit: { [weak self] in
            self?.quitCount += 1
        })
    }

    override func tearDown() async throws {
        observer.stop()
        observer = nil
        center = nil
        try await super.tearDown()
    }

    private func postWillClose(windowIdentifier: String?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.identifier = windowIdentifier.map { NSUserInterfaceItemIdentifier($0) }
        center.post(name: NSWindow.willCloseNotification, object: window)
    }

    /// The test host is the app, so its mailbox window is the `Window` scene's own. The
    /// observer knows that window by this identifier and by nothing else.
    ///
    /// Revert-check: giving the `Window` scene any other id than
    /// `MacMainWindowPolicy.windowID` in `esc_chatmailApp.body` makes this fail.
    func testAppsMailboxWindow_hasTheIdentifierTheObserverWatchesFor() {
        let identifiers = NSApp.windows.map { $0.identifier?.rawValue ?? "nil" }

        XCTAssertEqual(
            identifiers.filter { $0 == MacMainWindowPolicy.windowID }.count,
            1,
            "The test host's windows: \(identifiers)"
        )
    }

    /// Revert-check: deleting the `quit()` call from the block in
    /// `MacMainWindowCloseObserver.start` makes this fail.
    func testMailboxWindowCloses_asksToQuitOnce() {
        observer.start()

        postWillClose(windowIdentifier: MacMainWindowPolicy.windowID)

        XCTAssertEqual(quitCount, 1)
    }

    /// Revert-check: deleting the `guard MacMainWindowPolicy.closingQuitsApp(...)` from the
    /// block in `MacMainWindowCloseObserver.start` makes this fail: closing the Settings
    /// window would quit the app.
    func testAnotherWindowCloses_asksNothing() {
        observer.start()

        postWillClose(windowIdentifier: "com_apple_SwiftUI_Settings_window")
        postWillClose(windowIdentifier: nil)

        XCTAssertEqual(quitCount, 0)
    }

    func testBeforeStart_asksNothing() {
        postWillClose(windowIdentifier: MacMainWindowPolicy.windowID)

        XCTAssertEqual(quitCount, 0)
    }

    /// Revert-check: deleting the `guard observation == nil` from
    /// `MacMainWindowCloseObserver.start` makes this fail: one close would ask twice.
    func testStartedTwice_stillAsksOnce() {
        observer.start()
        observer.start()

        postWillClose(windowIdentifier: MacMainWindowPolicy.windowID)

        XCTAssertEqual(quitCount, 1)
    }

    /// Revert-check: deleting the `removeObserver` call from `MacMainWindowCloseObserver.stop`
    /// makes this fail.
    func testAfterStop_asksNothing() {
        observer.start()
        observer.stop()

        postWillClose(windowIdentifier: MacMainWindowPolicy.windowID)

        XCTAssertEqual(quitCount, 0)
    }
}
#endif
