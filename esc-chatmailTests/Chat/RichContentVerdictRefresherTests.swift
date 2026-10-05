import CoreData
import XCTest
@testable import esc_chatmail

/// `RichContentVerdictRefresher` re-stamps `Message.richContentVerdict` for one row whose
/// stored state changed outside sync. These tests call `refresh(messageID:handler:)`
/// directly against a private `SyncRunCoordinator`, an in-memory `TestCoreDataStack` and an
/// `HTMLContentHandler` on its own temporary Messages directory, so nothing here touches
/// the shared coordinator, the host app's store or the real Messages directory. The one
/// exception is the canonical loader's save-site test, which says why.
///
/// The suite is not main-actor isolated, so every fixture write and every assertion read
/// runs inside `performAndWait` on a throwaway background context. The refresher only ever
/// sees rows that were saved to the store.
final class RichContentVerdictRefresherTests: XCTestCase {
    /// Rich for `RichContentClassifier`: `<section>` is one of its always-rich markers.
    private static let richHTML = """
    <!DOCTYPE html>
    <html>
    <body>
      <section>
        <table role="presentation" width="100%">
          <tr><td><h1>Statement ready</h1></td></tr>
          <tr><td><p>Your monthly account statement is now available.</p></td></tr>
          <tr><td><a href="https://example.com/review">Review statement</a></td></tr>
        </table>
      </section>
    </body>
    </html>
    """

    /// Not rich: one paragraph, no structure, no newsletter markers.
    private static let plainHTML = "<html><body><p>See you at noon.</p></body></html>"

    /// What a personal message stores: no HTML tags, not raw source and not newsletter
    /// fallback text, so only an HTML file can make the row rich.
    private static let personalBodyText = "See you at noon."

    /// Reads like the "view in browser / unsubscribe" text a newsletter leaves in
    /// `bodyText` (a marker plus two URL lines). Such a row is rich as soon as it has an
    /// HTML source, whatever that HTML classifies as.
    private static let newsletterFallbackBodyText = """
    View in browser
    https://example.com/view
    Unsubscribe
    https://example.com/unsubscribe
    """

    /// A raw RFC 822 body with an HTML part, the shape `CanonicalEmailContentLoader`
    /// extracts HTML from and saves. Same fixture shape as
    /// `MessageBubbleLoaderTests.testLoadContent_rawEmailSourceWithEmbeddedHTML_marksRichContent`.
    private static let rawSourceWithEmbeddedHTML = """
    Delivered-To: person@example.com
    Received: by 2002:a05:6e04:71a:b0:3ac:63b9:5e27 with SMTP id o26csp2106356imz;
    X-Received: by 2002:ac8:7dd4:0:b0:503:4257:da03 with SMTP id d75a77;
    Return-Path: <newsletter@example.com>
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="newsletter-boundary-123"

    --newsletter-boundary-123
    Content-Type: text/plain; charset="utf-8"
    Content-Transfer-Encoding: quoted-printable

    Example Museum
    View in Browser
    Tickets are now on sale for the Spring Documentary Festival
    Learn More
    Unsubscribe

    --newsletter-boundary-123
    Content-Type: text/html; charset="utf-8"
    Content-Transfer-Encoding: quoted-printable

    <!DOCTYPE html>
    <html>
    <body>
      <table role=3D"presentation" width=3D"100%">
        <tr>
          <td>
            <p>View in Browser</p>
            <h1>Tickets are now on sale for the Spring Documentary Festival</h1>
            <p>Join us for a showcase of outstanding documentary films and immersive conversations around the world.</p>
            <table role=3D"presentation">
              <tr><td><a href=3D"https://example.com/learn-more">Learn More</a></td></tr>
            </table>
            <p><a href=3D"https://example.com/unsubscribe">Unsubscribe</a> | <a href=3D"https://example.com/preferences">Manage Preferences</a></p>
          </td>
        </tr>
      </table>
    </body>
    </html>

    --newsletter-boundary-123--
    """

    private var stack: TestCoreDataStack!
    private var coordinator: SyncRunCoordinator!
    private var directory: URL!
    private var handler: HTMLContentHandler!
    private var refresher: RichContentVerdictRefresher!

    override func setUp() {
        super.setUp()
        let stack = TestCoreDataStack()
        let coordinator = SyncRunCoordinator()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichContentVerdictRefresherTests-\(UUID().uuidString)", isDirectory: true)
        self.stack = stack
        self.coordinator = coordinator
        self.directory = directory
        handler = HTMLContentHandler(messagesDirectory: directory)
        refresher = RichContentVerdictRefresher(
            accountWorkCoordinator: coordinator,
            // Object-trump, which the refresher requires of its context factory.
            makeBackgroundContext: { stack.newBackgroundContext() },
            isEnabled: true
        )
    }

    override func tearDown() {
        // Tests that close HTML storage must not leave this directory's boundary closed.
        try? handler.reopenAccountWork()
        try? FileManager.default.removeItem(at: directory)
        refresher = nil
        handler = nil
        directory = nil
        coordinator = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - A stored verdict left behind by an HTML write

    /// The regression the refresher exists for: HTML reached disk for a row sync had
    /// stamped "not rich" (recovery fetched it), nothing re-stamped the row, and its bubble
    /// rendered text at mount and swapped to a card on every open.
    ///
    /// Revert-check: the `message.storedRichContentVerdict = verdict` write, and the save
    /// behind it, in `RichContentVerdictRefresher.refreshHoldingLease`.
    func testRefresh_storedNotRichThenRichHTMLWritten_updatesStoredVerdictToRich() async throws {
        let messageID = makeMessageID("not-rich-to-rich")
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))

        let outcome = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.rich])
    }

    /// The reverse: recovery replaced a rich file with HTML that is not rich, and the row
    /// would otherwise mount as a card and swap to text.
    ///
    /// Revert-check: the same write in `RichContentVerdictRefresher.refreshHoldingLease`.
    /// It must store whatever `RichContentVerdictResolver.verdict` answers, not only "rich".
    func testRefresh_storedRichThenPlainHTMLWritten_updatesStoredVerdictToNotRich() async throws {
        let messageID = makeMessageID("rich-to-not-rich")
        try insertMessage(id: messageID, storedVerdict: .rich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))
        XCTAssertNotNil(handler.saveHTML(Self.plainHTML, for: messageID))

        let outcome = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.notRich])
    }

    /// A row the launch backfill has not reached holds no verdict. "Not rich" is a known
    /// verdict and must be stored as one, or the bubble keeps its loading pill.
    ///
    /// Revert-check: the write in `RichContentVerdictRefresher.refreshHoldingLease` storing
    /// the resolver's verdict whatever it is. A refresher that only promoted rows to rich
    /// would leave this row unknown.
    func testRefresh_neverStampedRow_storesTheComputedVerdict() async throws {
        let messageID = makeMessageID("never-stamped")
        try insertMessage(id: messageID, storedVerdict: .unknown)
        XCTAssertNotNil(handler.saveHTML(Self.plainHTML, for: messageID))

        let outcome = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .updated)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.notRich])
    }

    /// `CanonicalEmailContentLoader`'s case: the classifier's answer did not change, but the
    /// row gained an HTML file, which makes a newsletter-fallback-text row rich.
    ///
    /// Revert-check: `RichContentVerdictRefresher.refreshHoldingLease` evaluating
    /// `RichContentVerdictResolver.verdict` (all of the rule) rather than the classifier on
    /// the saved HTML alone. The classifier calls this file's HTML not rich.
    func testRefresh_fallbackTextRowGainsHTMLFile_updatesStoredVerdictToRich() async throws {
        let messageID = makeMessageID("fallback-text")
        try insertMessage(
            id: messageID,
            storedVerdict: .notRich,
            bodyText: Self.newsletterFallbackBodyText
        )

        let withoutHTMLSource = await refresher.refresh(messageID: messageID, handler: handler)
        XCTAssertEqual(withoutHTMLSource, .unchanged, "Precondition: no HTML source, so the stored verdict was right")

        XCTAssertNotNil(handler.saveHTML(Self.plainHTML, for: messageID))
        let withHTMLSource = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(withHTMLSource, .updated)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.rich])
    }

    // MARK: - Nothing to write

    /// Revert-check: the `message.storedRichContentVerdict != verdict` comparison and the
    /// `guard didChange` exit in `RichContentVerdictRefresher.refreshHoldingLease`. Without
    /// them the refresh reports `.updated` for a row it did not change.
    ///
    /// HONEST SCOPE: does not pin the setter guard in `Message.storedRichContentVerdict`.
    /// The refresher's own comparison already keeps an equal verdict from being assigned.
    func testRefresh_storedVerdictAlreadyCorrect_returnsUnchangedWithoutSaving() async throws {
        let messageID = makeMessageID("already-correct")
        try insertMessage(id: messageID, storedVerdict: .rich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))
        let countingContext = makeSaveCountingContext()
        let refresher = makeRefresher { countingContext }

        let outcome = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(countingContext.saveAttempts, 0)
        let leftDirty = countingContext.performAndWait { countingContext.hasChanges }
        XCTAssertFalse(leftDirty, "An unchanged row must not be left dirty on the refresher's context")
        XCTAssertEqual(try storedVerdicts(of: messageID), [.rich])

        // Positive control: the same context does save once there is something to write.
        XCTAssertNotNil(handler.saveHTML(Self.plainHTML, for: messageID))
        let afterChange = await refresher.refresh(messageID: messageID, handler: handler)
        XCTAssertEqual(afterChange, .updated)
        XCTAssertEqual(countingContext.saveAttempts, 1)
    }

    /// The row can be gone by the time a scheduled refresh runs (sync deleted it).
    ///
    /// Revert-check: `guard !snapshots.isEmpty else { return .unchanged }` in
    /// `RichContentVerdictRefresher.refreshHoldingLease`. The closed-storage half is what
    /// needs it: with no row there is no stored state to fail to read, so the answer is
    /// `.unchanged`, never `.undetermined`.
    func testRefresh_noRowWithThatID_returnsUnchanged() async throws {
        let messageID = makeMessageID("no-row")
        let countingContext = makeSaveCountingContext()
        let refresher = makeRefresher { countingContext }

        let outcome = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(countingContext.saveAttempts, 0)
        XCTAssertEqual(try storedVerdicts(of: messageID), [], "A refresh must never create a row")

        handler.closeAccountWork()
        let whileStorageClosed = await refresher.refresh(messageID: messageID, handler: handler)
        XCTAssertEqual(whileStorageClosed, .unchanged)
    }

    // MARK: - Undetermined writes nothing

    /// A closed HTML boundary answers "absent" to every read. Stamping "not rich" from that
    /// would render a rich row's text at mount and swap it for a card on every open.
    ///
    /// Revert-check: the `guard verdict != .unknown` skip in the write loop of
    /// `RichContentVerdictRefresher.refreshHoldingLease`.
    ///
    /// HONEST SCOPE: the early `guard let generation = handler.captureAccountGeneration()`
    /// exit is not pinned on its own. With it gone the resolver answers `.unknown` for the
    /// same closed boundary and the outcome is the same.
    func testRefresh_htmlStorageClosed_returnsUndeterminedAndKeepsStoredVerdict() async throws {
        let messageID = makeMessageID("storage-closed")
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))
        let countingContext = makeSaveCountingContext()
        let refresher = makeRefresher { countingContext }

        handler.closeAccountWork()
        let whileClosed = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(whileClosed, .undetermined)
        XCTAssertEqual(countingContext.saveAttempts, 0)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.notRich])

        // The file was never deleted, so once storage reopens the same refresh can read it.
        try handler.reopenAccountWork()
        let afterReopen = await refresher.refresh(messageID: messageID, handler: handler)
        XCTAssertEqual(afterReopen, .updated)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.rich])
    }

    /// An HTML file that exists but cannot be decoded is not "no HTML": classifying the
    /// next candidate instead would call a row with rich HTML on disk "not rich".
    ///
    /// Revert-check: the `.undetermined` candidate for a file that exists and does not load
    /// in `RichContentVerdictResolver.classifierCandidate`, and the `guard verdict != .unknown`
    /// skip in `RichContentVerdictRefresher.refreshHoldingLease`. Falling through to the
    /// body text stores "not rich"; writing the unknown clears the stored verdict.
    func testRefresh_unreadableHTMLFile_returnsUndeterminedAndKeepsStoredVerdict() async throws {
        let messageID = makeMessageID("unreadable-file")
        // Written raw, and before the handler is asked about this ID: `saveHTML` only takes
        // a String, and the handler caches a "missing" signature for a file it looked for
        // before it existed.
        let fileURL = directory.appendingPathComponent("\(messageID).html")
        let invalidUTF8 = Data([0x3C, 0x70, 0x3E, 0xC3, 0x28, 0xFF, 0x3C, 0x2F, 0x70, 0x3E])
        try invalidUTF8.write(to: fileURL)
        XCTAssertTrue(handler.htmlFileExists(for: messageID), "Precondition: the file is on disk")
        XCTAssertNil(handler.loadHTML(for: messageID), "Precondition: the file does not decode as UTF-8")
        try insertMessage(id: messageID, storedVerdict: .rich)
        let countingContext = makeSaveCountingContext()
        let refresher = makeRefresher { countingContext }

        let outcome = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .undetermined)
        XCTAssertEqual(countingContext.saveAttempts, 0)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.rich])
    }

    // MARK: - Account boundary

    /// Boundary test. Once teardown owns the boundary the store is about to be replaced:
    /// a refresh must neither read nor write it, and must work again for the next account.
    ///
    /// Revert-check: the `makeAccountWorkRequest()` / `acquireAccountWorkLease(kind:for:)`
    /// guard at the top of `RichContentVerdictRefresher.refresh`.
    ///
    /// HONEST SCOPE: not the literal "stale generation is rejected after reopen" shape. The
    /// refresher makes its request and takes its lease back to back and keeps no token
    /// across a suspension, so there is no stale token to present after the reopen.
    func testRefresh_requestedDuringAccountTransition_isSkippedUntilTheTransitionEnds() async throws {
        let messageID = makeMessageID("during-transition")
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))
        let contextRequested = VerdictRefresherTestFlag()
        let countingContext = makeSaveCountingContext()
        let refresher = makeRefresher {
            contextRequested.set()
            return countingContext
        }

        // Nothing holds the boundary, so teardown acquires it immediately.
        await coordinator.beginQuiescence()
        let duringTransition = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(duringTransition, .skipped)
        XCTAssertFalse(contextRequested.isSet, "A refused refresh must not open a context on the store")
        XCTAssertEqual(countingContext.saveAttempts, 0)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.notRich])

        await coordinator.endQuiescence()
        let afterTransition = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(afterTransition, .updated)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.rich])
    }

    /// Teardown drains leases before it closes HTML storage or replaces the store. The
    /// refresh is parked between classifying and writing, the point where it would
    /// otherwise write into whatever the store has become.
    ///
    /// Revert-check: the lease `RichContentVerdictRefresher.refresh` holds across
    /// `refreshHoldingLease`. Released early, or never taken, `beginQuiescence()` returns
    /// while the write is still to come.
    func testRefresh_inFlight_accountTransitionWaitsForItsLease() async throws {
        // Non-optional locals, declared before first use: the tasks below capture them.
        let coordinator: SyncRunCoordinator = self.coordinator
        let handler: HTMLContentHandler = self.handler
        let messageID = makeMessageID("in-flight")
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))

        let reachedWrite = VerdictRefresherTestFlag()
        let allowWrite = DispatchSemaphore(value: 0)
        let hookContext = makeWritePhaseHookContext {
            reachedWrite.set()
            // Parks the context's own queue, not a cooperative thread. Bounded so a failed
            // test cannot leave it parked for the rest of the run.
            _ = allowWrite.wait(timeout: .now() + 30)
        }
        let parkedRefresher = makeRefresher { hookContext }
        let outcome = VerdictRefresherOutcomeBox()
        Task {
            let result = await parkedRefresher.refresh(messageID: messageID, handler: handler)
            outcome.set(result)
        }
        let didReachWrite = await waitUntil { reachedWrite.isSet }
        XCTAssertTrue(didReachWrite, "Precondition: the refresh is parked before its write, holding its lease")

        let drained = VerdictRefresherTestFlag()
        Task {
            await coordinator.beginQuiescence()
            drained.set()
        }
        let transitionStarted = await waitUntil { await coordinator.makeAccountWorkRequest() == nil }
        XCTAssertTrue(transitionStarted, "Precondition: teardown has closed admission")
        // A drain that does not wait finishes in the same actor turn that closed admission.
        let drainedWhileLeaseHeld = await waitUntil(timeout: 0.3) { drained.isSet }
        XCTAssertFalse(drainedWhileLeaseHeld, "Account teardown must wait for a refresh that holds its lease")

        allowWrite.signal()
        let didDrain = await waitUntil { drained.isSet }
        XCTAssertTrue(didDrain, "Teardown proceeds once the refresh releases its lease")
        let didFinish = await waitUntil { outcome.value != nil }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(outcome.value, .updated, "A lease granted before teardown lets the write finish")
        XCTAssertEqual(try storedVerdicts(of: messageID), [.rich])
        if didDrain {
            await coordinator.endQuiescence()
        }
    }

    /// Sign-out waits for outstanding leases and cannot cancel them, so one leaked lease
    /// hangs every later account transition.
    ///
    /// Revert-check: `await accountWorkCoordinator.endRun(lease)` after `refreshHoldingLease`
    /// in `RichContentVerdictRefresher.refresh`, on every exit: the first drain below then
    /// never completes. An early `return` added inside `refresh` between the lease and that
    /// release fails the step for its outcome.
    func testRefresh_everyOutcome_releasesItsLease() async throws {
        let messageID = makeMessageID("lease-release")
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))

        let updated = await refresher.refresh(messageID: messageID, handler: handler)
        XCTAssertEqual(updated, .updated)
        guard await assertAccountTransitionDrains(after: "updated the row") else { return }

        let unchanged = await refresher.refresh(messageID: messageID, handler: handler)
        XCTAssertEqual(unchanged, .unchanged)
        guard await assertAccountTransitionDrains(after: "found the row already correct") else { return }

        let noRow = await refresher.refresh(messageID: makeMessageID("lease-no-row"), handler: handler)
        XCTAssertEqual(noRow, .unchanged)
        guard await assertAccountTransitionDrains(after: "found no row") else { return }

        handler.closeAccountWork()
        let undetermined = await refresher.refresh(messageID: messageID, handler: handler)
        XCTAssertEqual(undetermined, .undetermined)
        try handler.reopenAccountWork()
        guard await assertAccountTransitionDrains(after: "could not read HTML storage") else { return }

        // The stored verdict is "rich" by now, so plain HTML gives the failing save a write.
        XCTAssertNotNil(handler.saveHTML(Self.plainHTML, for: messageID))
        let failingSaveContext = makeFailingSaveContext()
        let failingSaveRefresher = makeRefresher { failingSaveContext }
        let failedSave = await failingSaveRefresher.refresh(messageID: messageID, handler: handler)
        XCTAssertEqual(failedSave, .skipped)
        XCTAssertEqual(failingSaveContext.saveAttempts, 1, "Positive control: the save was attempted")
        guard await assertAccountTransitionDrains(after: "failed to save") else { return }

        let failingFetchContext = try FailingReadStore.makeFailingContext()
        let failingFetchRefresher = makeRefresher { failingFetchContext }
        let failedFetch = await failingFetchRefresher.refresh(messageID: messageID, handler: handler)
        XCTAssertEqual(failedFetch, .skipped)
        await assertAccountTransitionDrains(after: "failed to read the row")
    }

    /// The lease is the non-exclusive kind: a refresh is not serialized behind a sync run
    /// that can hold the single-flight boundary for minutes.
    ///
    /// Revert-check: `acquireAccountWorkLease(kind:for:)` in `RichContentVerdictRefresher.refresh`.
    /// `acquireRun(kind:for:)` parks behind the held run and the refresh never finishes here.
    func testRefresh_whileExclusiveSyncRunIsActive_completesWithoutWaitingForIt() async throws {
        // Non-optional locals, declared before first use: the task below captures them.
        let leasingRefresher: RichContentVerdictRefresher = self.refresher
        let handler: HTMLContentHandler = self.handler
        let messageID = makeMessageID("during-sync")
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))
        guard let blockingRun = await coordinator.beginRun(kind: .foregroundIncremental) else {
            return XCTFail("Expected a foreground run to hold the exclusive boundary")
        }

        let outcome = VerdictRefresherOutcomeBox()
        Task {
            let result = await leasingRefresher.refresh(messageID: messageID, handler: handler)
            outcome.set(result)
        }
        let didFinish = await waitUntil { outcome.value != nil }

        XCTAssertTrue(didFinish, "The refresh must not wait for the exclusive sync run")
        XCTAssertEqual(outcome.value, .updated)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.rich])

        await coordinator.endRun(blockingRun)
    }

    // MARK: - Own rows

    /// Own rows are never rich, whatever HTML sits on disk under their ID.
    ///
    /// Revert-check: `guard !inputs.isFromMe else { return .notRich }` in
    /// `RichContentVerdictResolver.verdict`, as `RichContentVerdictRefresher` reaches it.
    func testRefresh_ownRow_staysNotRichWhateverHTMLIsOnDisk() async throws {
        let messageID = makeMessageID("own-row")
        try insertMessage(id: messageID, isFromMe: true, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))

        let outcome = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.notRich])

        // A stale "rich" on an own row is corrected, not kept.
        let staleMessageID = makeMessageID("own-row-stale")
        try insertMessage(id: staleMessageID, isFromMe: true, storedVerdict: .rich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: staleMessageID))

        let staleOutcome = await refresher.refresh(messageID: staleMessageID, handler: handler)

        XCTAssertEqual(staleOutcome, .updated)
        XCTAssertEqual(try storedVerdicts(of: staleMessageID), [.notRich])
    }

    // MARK: - A row that changed while the refresh classified

    /// Sync rewrote the row between the refresher's read and its write. Sync stamps the
    /// verdict of the state it wrote in the same save, so the verdict this refresh computed
    /// from the old state must not land on top of it.
    ///
    /// Revert-check: `message.richContentVerdictInputs == snapshot.inputs` in the write
    /// loop of `RichContentVerdictRefresher.refreshHoldingLease`.
    func testRefresh_rowRewrittenWhileClassifying_leavesTheRowToSync() async throws {
        let messageID = makeMessageID("rewritten")
        let rewrittenBody = "Sync rewrote this body while the refresh was classifying."
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))
        let stack: TestCoreDataStack = self.stack
        let hookContext = makeWritePhaseHookContext {
            do {
                try RichContentVerdictRefresherTests.rewriteStoredRow(id: messageID, in: stack) { message, _ in
                    message.bodyText = rewrittenBody
                }
            } catch {
                XCTFail("The concurrent rewrite must land: \(error)")
            }
        }
        let refresher = makeRefresher { hookContext }

        let outcome = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.notRich])
        let storedBodies = try readRows(withID: messageID) { $0.bodyText }
        XCTAssertEqual(storedBodies, [rewrittenBody], "Positive control: the rewrite landed before the refresh re-read the row")
    }

    /// Sync deleted the row between the refresher's read and its write.
    ///
    /// Revert-check: the `try? context.existingObject(with:)` re-read in the write loop of
    /// `RichContentVerdictRefresher.refreshHoldingLease`. Writing to the object the first
    /// read registered instead fails the save or brings the row back.
    func testRefresh_rowDeletedWhileClassifying_writesNothing() async throws {
        let messageID = makeMessageID("deleted")
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))
        let stack: TestCoreDataStack = self.stack
        let hookContext = makeWritePhaseHookContext {
            do {
                try RichContentVerdictRefresherTests.rewriteStoredRow(id: messageID, in: stack) { message, writer in
                    writer.delete(message)
                }
            } catch {
                XCTFail("The concurrent delete must land: \(error)")
            }
        }
        let refresher = makeRefresher { hookContext }

        let outcome = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(try storedVerdicts(of: messageID), [], "A refresh must not bring a deleted row back")
    }

    // MARK: - Failed reads and saves

    /// Revert-check: `guard context.saveOrLog(...) else { context.rollback(); return .skipped }`
    /// in `RichContentVerdictRefresher.refreshHoldingLease`. Reporting `.updated` for a save
    /// that failed, or leaving the failed change pending on the context, fails this.
    func testRefresh_failedSave_returnsSkippedAndRollsBack() async throws {
        let messageID = makeMessageID("failed-save")
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))
        let failingContext = makeFailingSaveContext()
        let refresher = makeRefresher { failingContext }

        let outcome = await refresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(failingContext.saveAttempts, 1, "Positive control: the write reached the save")
        let leftDirty = failingContext.performAndWait { failingContext.hasChanges }
        XCTAssertFalse(leftDirty, "A failed save must be rolled back")
        XCTAssertEqual(try storedVerdicts(of: messageID), [.notRich])
    }

    /// A failed Core Data read is never "no such row".
    ///
    /// Revert-check: the `catch` that makes the row read answer nil, and
    /// `guard let snapshots else { return .skipped }`, in
    /// `RichContentVerdictRefresher.refreshHoldingLease`. Reading the failure as an empty
    /// result reports `.unchanged`.
    func testRefresh_failedFetch_returnsSkipped() async throws {
        let failingContext = try FailingReadStore.makeFailingContext()
        let refresher = makeRefresher { failingContext }

        let outcome = await refresher.refresh(messageID: makeMessageID("failed-fetch"), handler: handler)

        XCTAssertEqual(outcome, .skipped)
    }

    // MARK: - Inert under unit tests, and scheduling

    /// Many suites construct services that default to the shared refresher against
    /// temporary HTML directories. A live one would lease `SyncRunCoordinator.shared` and
    /// read the test host's real store after each of their saves.
    ///
    /// Revert-check: `RichContentVerdictRefresher.shared` being built with `isEnabled: false`
    /// under `RuntimeEnvironment.isRunningUnitTests`. A live shared instance finds no such
    /// row in the host store and answers `.unchanged`.
    func testSharedRefresher_underUnitTests_isInert() async {
        let outcome = await RichContentVerdictRefresher.shared.refresh(
            messageID: makeMessageID("shared-inert"),
            handler: handler
        )

        XCTAssertEqual(outcome, .skipped)
    }

    /// Revert-check: the `isEnabled` term of the guard at the top of
    /// `RichContentVerdictRefresher.refresh`.
    func testRefresh_disabledRefresher_returnsSkippedWithoutReading() async throws {
        let messageID = makeMessageID("disabled")
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))
        let contextRequested = VerdictRefresherTestFlag()
        let stack: TestCoreDataStack = self.stack
        let disabledRefresher = makeRefresher(isEnabled: false) {
            contextRequested.set()
            return stack.newBackgroundContext()
        }

        let outcome = await disabledRefresher.refresh(messageID: messageID, handler: handler)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertFalse(contextRequested.isSet)
        XCTAssertEqual(try storedVerdicts(of: messageID), [.notRich])
    }

    /// Revert-check: the task `RichContentVerdictRefresher.scheduleRefresh` starts to run
    /// `refresh(messageID:handler:)`.
    ///
    /// HONEST SCOPE: cannot tell `Task.detached` from a plain `Task {}`. The difference is
    /// the priority and context the refresh inherits from a save site, which no outcome
    /// here observes.
    func testScheduleRefresh_enabledRefresher_eventuallyUpdatesStoredVerdict() async throws {
        let messageID = makeMessageID("scheduled")
        try insertMessage(id: messageID, storedVerdict: .notRich)
        XCTAssertNotNil(handler.saveHTML(Self.richHTML, for: messageID))

        refresher.scheduleRefresh(messageID: messageID, handler: handler)

        let didUpdate = await waitUntil { storedVerdictIs(.rich, for: messageID) }
        XCTAssertTrue(didUpdate, "A scheduled refresh must re-stamp the row without being awaited")
        // The scheduled task can still be between its save and its lease release. Draining
        // the boundary keeps it from outliving this test's store and directory.
        await assertAccountTransitionDrains(after: "was scheduled")
    }

    // MARK: - CanonicalEmailContentLoader save site

    /// Extracting HTML from a raw-source body and saving it gives the row an HTML file its
    /// stored verdict predates.
    ///
    /// Revert-check: the `richContentVerdictRefresher.scheduleRefresh(messageID:handler:)`
    /// call after the successful `saveHTML` in
    /// `CanonicalEmailContentLoader.loadCanonicalEmailContent`.
    ///
    /// HONEST SCOPE: this is the one test here on the real Messages directory. The loader
    /// captures its invalidation context from `HTMLContentLoader.shared`, which rejects a
    /// token from any other directory, so an isolated handler never reaches the save. The
    /// message ID is unique and its file is deleted afterwards. A recording double stands in
    /// for the refresher: that a scheduled refresh re-stamps the row is pinned above.
    func testCanonicalEmailContentLoader_rawSourceHTMLSaved_schedulesOneRefreshForThatMessage() async {
        let messageID = makeMessageID("canonical-save-site")
        let contentHandler = HTMLContentHandler()
        defer { contentHandler.deleteHTML(for: messageID) }
        let recorder = VerdictRefresherSaveSiteRecorder()
        let loader = CanonicalEmailContentLoader(
            contentHandler: contentHandler,
            recoveryService: VerdictRefresherNoopRecoverer(),
            richContentVerdictRefresher: recorder
        )

        let saved = await loader.loadCanonicalEmailContent(
            messageId: messageID,
            bodyStorageURI: nil,
            bodyText: Self.rawSourceWithEmbeddedHTML,
            allowRecovery: false
        )

        XCTAssertEqual(saved?.sourceLocation, .rawSourceHTML, "Positive control: the raw-source path ran")
        XCTAssertTrue(contentHandler.htmlFileExists(for: messageID), "Positive control: the save site was reached")
        XCTAssertEqual(recorder.messageIDs, [messageID])
        XCTAssertTrue(
            recorder.handlers.first === contentHandler,
            "The refresh must read through the handler that holds the saved file"
        )

        // The second load reads the file the first one saved. Nothing is written, so
        // nothing is scheduled.
        let reloaded = await loader.loadCanonicalEmailContent(
            messageId: messageID,
            bodyStorageURI: nil,
            bodyText: Self.rawSourceWithEmbeddedHTML,
            allowRecovery: false
        )

        XCTAssertEqual(reloaded?.sourceLocation, .messageFile)
        XCTAssertEqual(recorder.messageIDs, [messageID], "A load that saves nothing must not schedule a refresh")
    }

    // MARK: - Fixture preconditions

    /// HONEST SCOPE: not a regression test, and no production change makes it the only
    /// failure. It states the classifier facts the fixtures above lean on, so a classifier
    /// change that flips one fails here with a readable message.
    func testFixtures_classifyAsTheSuiteAssumes() {
        XCTAssertTrue(RichContentClassifier.hasGenuineRichContentAfterCleanup(Self.richHTML))
        XCTAssertFalse(RichContentClassifier.hasGenuineRichContentAfterCleanup(Self.plainHTML))
        XCTAssertFalse(NewsletterFallbackText.looksLikeFallbackText(Self.personalBodyText))
        XCTAssertTrue(NewsletterFallbackText.looksLikeFallbackText(Self.newsletterFallbackBodyText))
    }

    // MARK: - Helpers

    private func makeMessageID(_ label: String) -> String {
        "verdict-refresh-\(label)-\(UUID().uuidString)"
    }

    private func makeRefresher(
        isEnabled: Bool = true,
        makeBackgroundContext: @escaping @Sendable () -> NSManagedObjectContext
    ) -> RichContentVerdictRefresher {
        RichContentVerdictRefresher(
            accountWorkCoordinator: coordinator,
            makeBackgroundContext: makeBackgroundContext,
            isEnabled: isEnabled
        )
    }

    /// A store-backed context whose saves all succeed and are counted.
    private func makeSaveCountingContext() -> ScriptedSaveContext {
        let context = ScriptedSaveContext(
            error: NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectContextLockingError),
            failingFromAttempt: .max
        )
        context.persistentStoreCoordinator = stack.persistentContainer.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    /// A store-backed context that reads normally and fails every save.
    private func makeFailingSaveContext() -> ScriptedSaveContext {
        let context = ScriptedSaveContext(
            error: NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectContextLockingError)
        )
        context.persistentStoreCoordinator = stack.persistentContainer.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    private func makeWritePhaseHookContext(
        beforeWrite hook: @escaping () -> Void
    ) -> VerdictRefresherWritePhaseHookContext {
        let context = VerdictRefresherWritePhaseHookContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = stack.persistentContainer.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.beforeRefreshAllObjects = hook
        return context
    }

    /// Inserts one saved `Message` row. `bodyText` and `snippet` default to text that
    /// decides nothing, so the row's verdict follows its HTML file.
    private func insertMessage(
        id: String,
        isFromMe: Bool = false,
        storedVerdict: RichContentVerdict,
        bodyText: String? = RichContentVerdictRefresherTests.personalBodyText,
        snippet: String? = RichContentVerdictRefresherTests.personalBodyText
    ) throws {
        let context = stack.newBackgroundContext()
        try context.performAndWait {
            let message = MessageBuilder().withId(id).build(in: context)
            message.isFromMe = isFromMe
            message.bodyText = bodyText
            message.snippet = snippet
            message.storedRichContentVerdict = storedVerdict
            try context.save()
        }
    }

    /// Reads the saved rows with this ID on a fresh context, so the answer is what the
    /// store holds and not what some context still has registered.
    private func readRows<Value>(
        withID messageID: String,
        _ read: (Message) -> Value
    ) throws -> [Value] {
        let context = stack.newBackgroundContext()
        return try context.performAndWait { () throws -> [Value] in
            let request: NSFetchRequest<Message> = Message.fetchRequest()
            request.predicate = MessagePredicates.id(messageID)
            return try context.fetch(request).map(read)
        }
    }

    private func storedVerdicts(of messageID: String) throws -> [RichContentVerdict] {
        try readRows(withID: messageID) { $0.storedRichContentVerdict }
    }

    private func storedVerdictIs(_ expected: RichContentVerdict, for messageID: String) -> Bool {
        (try? storedVerdicts(of: messageID)) == [expected]
    }

    /// Changes the saved row on its own context and saves, as a concurrent writer would.
    /// Static so a context hook can call it without capturing the test case.
    private static func rewriteStoredRow(
        id messageID: String,
        in stack: TestCoreDataStack,
        _ change: (Message, NSManagedObjectContext) -> Void
    ) throws {
        let writer = stack.newBackgroundContext()
        try writer.performAndWait {
            let request: NSFetchRequest<Message> = Message.fetchRequest()
            request.predicate = MessagePredicates.id(messageID)
            let message = try XCTUnwrap(writer.fetch(request).first, "Expected a saved row to rewrite")
            change(message, writer)
            try writer.save()
        }
    }

    /// Polls until `condition` holds or the wall-clock deadline passes, and says which.
    /// The default is a liveness bound a green run never reaches: `scheduleRefresh` runs at
    /// utility priority, polling lends it none, and a loaded CI VM can leave low-priority
    /// work unscheduled for seconds.
    private func waitUntil(
        timeout: TimeInterval = 30.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await condition()
    }

    /// Starts an account transition and requires it to drain within the deadline, then ends
    /// it again. A leaked lease parks `beginQuiescence()` for good (lease waits cannot be
    /// cancelled), so the drain runs in its own task and is raced against the clock rather
    /// than awaited. `testRefresh_inFlight_accountTransitionWaitsForItsLease` is the
    /// positive control: a held lease does keep this drain from completing.
    @discardableResult
    private func assertAccountTransitionDrains(
        after refreshDescription: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let coordinator: SyncRunCoordinator = self.coordinator
        let drained = VerdictRefresherTestFlag()
        Task {
            await coordinator.beginQuiescence()
            drained.set()
        }
        let didDrain = await waitUntil { drained.isSet }
        XCTAssertTrue(
            didDrain,
            "Account teardown is still waiting on a lease after a refresh that \(refreshDescription)",
            file: file,
            line: line
        )
        if didDrain {
            await coordinator.endQuiescence()
        }
        return didDrain
    }
}

/// A store-backed private-queue context that runs `beforeRefreshAllObjects` once, on its
/// own queue, at the top of `refreshAllObjects()`. That call is the first thing the
/// refresher does when it comes back from classifying to write, and the only point between
/// its read and its write that a test can reach.
///
/// The hook is set before the context is handed to the refresher and is then read and
/// cleared only on the context's queue, which is what the unchecked conformance rests on.
private final class VerdictRefresherWritePhaseHookContext: NSManagedObjectContext, @unchecked Sendable {
    var beforeRefreshAllObjects: (() -> Void)?

    override func refreshAllObjects() {
        let hook = beforeRefreshAllObjects
        beforeRefreshAllObjects = nil
        hook?()
        super.refreshAllObjects()
    }
}

/// Records `scheduleRefresh` calls instead of refreshing. `lock` guards both arrays.
private final class VerdictRefresherSaveSiteRecorder: RichContentVerdictRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMessageIDs: [String] = []
    private var recordedHandlers: [HTMLContentHandler] = []

    var messageIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedMessageIDs
    }

    var handlers: [HTMLContentHandler] {
        lock.lock()
        defer { lock.unlock() }
        return recordedHandlers
    }

    func scheduleRefresh(messageID: String, handler: HTMLContentHandler) {
        lock.lock()
        recordedMessageIDs.append(messageID)
        recordedHandlers.append(handler)
        lock.unlock()
    }
}

/// The canonical loader's save-site test passes `allowRecovery: false`, so this is never
/// asked. It only keeps the loader off `HTMLContentRecoveryService.shared`.
private struct VerdictRefresherNoopRecoverer: HTMLContentRecovering {
    func recoverHTMLContent(messageId: String) async -> String? { nil }
}

/// A boolean set from one task and read from another. `lock` guards `value`.
private final class VerdictRefresherTestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// The outcome of a refresh that runs in its own task. `lock` guards `stored`.
private final class VerdictRefresherOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RichContentVerdictRefresher.Outcome?

    var value: RichContentVerdictRefresher.Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ outcome: RichContentVerdictRefresher.Outcome) {
        lock.lock()
        stored = outcome
        lock.unlock()
    }
}
