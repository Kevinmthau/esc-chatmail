import XCTest

/// Pins from source what `MacAppDelegate.applicationShouldTerminate` does for reply
/// drafts, because no test can run it: the quit is AppKit's, and no Mac app may be
/// launched here. The halves it calls are run by `ChatViewModelTests` (the flush and the
/// count), `AppLifecyclePolicyTests` (the decision) and `AppTerminationWaitTests` (the
/// wait).
final class MacQuitDraftFlushSourceTests: XCTestCase {

    /// Revert-check: moving `composerDirectory.flushPresentedDraftsForTermination()`
    /// below the `terminationDecision` call in `MacAppDelegate.applicationShouldTerminate`
    /// makes this fail: the decision would read the tracker before the saves the debounce
    /// owed were started, answer `.terminateNow`, and lose the words typed in the last
    /// 350 ms as before.
    func testApplicationShouldTerminate_flushesDraftsBeforeItDecides() throws {
        let body = try applicationShouldTerminateBody()

        let flush = try XCTUnwrap(body.range(of: "composerDirectory.flushPresentedDraftsForTermination()"))
        let decision = try XCTUnwrap(body.range(of: "AppLifecyclePolicy.terminationDecision("))
        XCTAssertLessThan(flush.lowerBound, decision.lowerBound, body)
    }

    /// Revert-check: passing `hasOutstandingDraftWrites: false` to the decision, or
    /// calling the wait without `draftWrites: draftWriteTracker`, in
    /// `MacAppDelegate.applicationShouldTerminate` makes this fail.
    func testApplicationShouldTerminate_decidesAndWaitsOnTheDraftWriteTracker() throws {
        let body = try applicationShouldTerminateBody()

        XCTAssertTrue(body.contains("let draftWriteTracker = composerDirectory.draftWriteTracker"), body)
        XCTAssertTrue(body.contains("hasOutstandingDraftWrites: draftWriteTracker.hasOutstandingWrites"), body)
        XCTAssertTrue(body.contains("AppTerminationWait.waitForOutstandingWork("), body)
        XCTAssertTrue(body.contains("draftWrites: draftWriteTracker,"), body)
    }

    /// One reply, from one main-actor task, after the wait: AppKit takes the first.
    ///
    /// Revert-check: adding a second `sender.reply(toApplicationShouldTerminate:)` (one
    /// that answers before the wait, say) to `MacAppDelegate.applicationShouldTerminate`
    /// makes this fail.
    func testApplicationShouldTerminate_repliesOnceFromOneTask() throws {
        let body = try applicationShouldTerminateBody()

        XCTAssertEqual(body.components(separatedBy: "sender.reply(toApplicationShouldTerminate: true)").count - 1, 1, body)
        XCTAssertEqual(body.components(separatedBy: "Task {").count - 1, 1, body)
        let wait = try XCTUnwrap(body.range(of: "await AppTerminationWait.waitForOutstandingWork("))
        let reply = try XCTUnwrap(body.range(of: "sender.reply(toApplicationShouldTerminate: true)"))
        XCTAssertLessThan(wait.lowerBound, reply.lowerBound, body)
    }

    /// The body of `applicationShouldTerminate`, comments left out.
    private func applicationShouldTerminateBody(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let delegate = try repositorySource("esc-chatmail/Platform/MacAppDelegate.swift", file: file, line: line)
        let start = try XCTUnwrap(
            delegate.range(of: "func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {"),
            file: file,
            line: line
        )
        let end = try XCTUnwrap(
            delegate.range(of: "\n    }\n", range: start.upperBound..<delegate.endIndex),
            file: file,
            line: line
        )
        return delegate[start.upperBound..<end.lowerBound]
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
