import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the rich-content verdict sync stamps on a `Message` row
/// (`MessagePersister.stampRichContentVerdict`) on the create and update
/// paths, plus the preparation-phase pre-run that feeds it.
///
/// Stored verdicts are read back through a fresh context after the writing
/// context saved: the persister only stages, so this asserts what the save
/// committed with the row. HTML goes through an isolated `HTMLContentHandler`,
/// so nothing touches the real Messages directory or its account boundary.
final class MessagePersisterRichContentVerdictTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var messagesDirectory: URL!
    private var handler: HTMLContentHandler!

    override func setUp() async throws {
        try await super.setUp()
        testStack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessagePersisterRichContentVerdict-\(UUID().uuidString)", isDirectory: true)
        handler = HTMLContentHandler(messagesDirectory: messagesDirectory)
    }

    override func tearDown() async throws {
        if let messagesDirectory {
            try? FileManager.default.removeItem(at: messagesDirectory)
        }
        handler = nil
        messagesDirectory = nil
        coreDataStack = nil
        testStack = nil
        try await super.tearDown()
    }

    // MARK: - Fixture guard

    /// HONEST SCOPE: guards this file's fixtures, not a production change.
    /// Every test below leans on these classifications; if a classifier or
    /// fallback-text change moves one, this fails first and says why.
    func testFixtures_classifierAndFallbackPredicate_agreeWithFixtureNames() {
        XCTAssertTrue(RichContentClassifier.hasGenuineRichContentAfterCleanup(RichVerdictFixture.richHTML))
        XCTAssertFalse(RichContentClassifier.hasGenuineRichContentAfterCleanup(RichVerdictFixture.personalHTML))
        XCTAssertTrue(NewsletterFallbackText.looksLikeFallbackText(RichVerdictFixture.newsletterFallbackText))
        XCTAssertFalse(NewsletterFallbackText.looksLikeFallbackText(RichVerdictFixture.plainBody))
        XCTAssertFalse(NewsletterFallbackText.looksLikeFallbackText(RichVerdictFixture.editedPlainBody))
        XCTAssertFalse(NewsletterFallbackText.looksLikeFallbackText(RichVerdictFixture.snippet))
    }

    // MARK: - Create path

    func testSaveMessages_batchOfNewRows_stampsEachRowFromItsStoredState() async throws {
        let richID = uniqueID("create-rich")
        let personalID = uniqueID("create-personal")
        let ownID = uniqueID("create-own")
        let context = testStack.newBackgroundContext()

        let report = try await makePersister().saveMessages(
            [
                makeGmailMessage(id: richID, html: RichVerdictFixture.richHTML),
                makeGmailMessage(id: personalID, html: RichVerdictFixture.personalHTML),
                makeGmailMessage(id: ownID, fromMe: true, html: RichVerdictFixture.richHTML)
            ],
            myAliases: RichVerdictFixture.myAliases,
            in: context
        )
        XCTAssertEqual(Set(report.persistedIds), [richID, personalID, ownID])
        try await commit(context)

        // Revert-check: the stampRichContentVerdict call in
        // MessagePersister+Creation.swift. Without it each row keeps the model
        // default (raw 0, unknown) and all three verdict assertions fail.
        //
        // HONEST SCOPE: through the real pipeline the pre-run and the
        // classifier agree, so this pins that a verdict is stamped, not which
        // of the two produced it (the pre-run tests below do that).
        let richRow = try await storedRow(id: richID)
        XCTAssertEqual(richRow.verdict, .rich)
        XCTAssertEqual(richRow.rawVerdict, RichContentVerdict.rich.storedValue())

        let personalRow = try await storedRow(id: personalID)
        XCTAssertEqual(personalRow.verdict, .notRich)

        // An own row is never rich, whatever its HTML. `.notRich` rather than
        // `.unknown` is what shows it was stamped at all.
        let ownRow = try await storedRow(id: ownID)
        XCTAssertTrue(ownRow.inputs.isFromMe)
        XCTAssertNotNil(ownRow.inputs.bodyStorageURI)
        XCTAssertEqual(ownRow.verdict, .notRich)
    }

    // MARK: - Pre-run

    func testPrepareMessage_htmlPartEndingInLineBreak_prerunClassifiesTheStringThePersisterSaves() async throws {
        let id = uniqueID("prerun-trim")
        let persister = makePersister()
        let gmailMessage = makeGmailMessage(id: id, html: RichVerdictFixture.richHTML + "\n")

        let prepared = try await persister.prepareMessage(
            gmailMessage,
            myAliases: RichVerdictFixture.myAliases
        )
        guard case .processed(let processed) = prepared else {
            return XCTFail("The real processor should produce a processed message")
        }
        let storedHTML = try XCTUnwrap(processed.storedHTML)
        let prerun = try XCTUnwrap(processed.richContentPrerun)

        // Fixture guard: the processor keeps the part untrimmed, so the two
        // strings really differ. If they were one string this proves nothing.
        XCTAssertNotEqual(processed.htmlBody, storedHTML)
        XCTAssertEqual(
            processed.htmlBody?.trimmingCharacters(in: .whitespacesAndNewlines),
            storedHTML
        )

        // Revert-check: MessagePersister.richContentPrerun(for:) classifying
        // `storedHTML`. Keyed to `htmlBody` (the untrimmed part) the pre-run
        // would never match the saved string and would silently go unused.
        XCTAssertEqual(prerun.html, storedHTML)
        XCTAssertEqual(
            prerun.isRich,
            RichContentClassifier.hasGenuineRichContentAfterCleanup(storedHTML)
        )

        // The string on disk is the pre-run's string, byte for byte.
        try await persist(gmailMessage, using: persister)
        let savedFile = try String(
            contentsOf: messagesDirectory.appendingPathComponent("\(id).html"),
            encoding: .utf8
        )
        XCTAssertEqual(savedFile, prerun.html)
        let row = try await storedRow(id: id)
        XCTAssertEqual(row.verdict, .rich)
    }

    func testCreateNewMessage_prerunForTheSavedString_storedVerdictFollowsThePrerun() async throws {
        let persister = makePersister()

        // Both pre-runs deliberately contradict the classifier (see the
        // fixture guard), so the stored verdict shows whose answer was used.
        //
        // Revert-check: the `prerun.html == html` reuse in
        // MessagePersister.stampRichContentVerdict. Classifying again instead
        // stores the classifier's answer and both assertions fail.
        //
        // HONEST SCOPE: the classifier is a static function with no seam, so
        // "no second classification" is inferred from the wrong answer
        // surviving, not counted.
        let personalRow = try await createRow(
            makeProcessedMessage(
                id: uniqueID("prerun-reuse-personal"),
                html: RichVerdictFixture.personalHTML,
                prerun: RichContentPrerun(html: RichVerdictFixture.personalHTML, isRich: true)
            ),
            using: persister
        )
        XCTAssertEqual(personalRow.verdict, .rich)

        let richRow = try await createRow(
            makeProcessedMessage(
                id: uniqueID("prerun-reuse-rich"),
                html: RichVerdictFixture.richHTML,
                prerun: RichContentPrerun(html: RichVerdictFixture.richHTML, isRich: false)
            ),
            using: persister
        )
        XCTAssertEqual(richRow.verdict, .notRich)
    }

    func testCreateNewMessage_prerunForADifferentString_classifierDecides() async throws {
        let persister = makePersister()

        // The pre-runs carry the untrimmed part, the mismatch the guard exists
        // for, with an answer that contradicts the classifier.
        //
        // Revert-check: the `prerun.html == html` guard in
        // MessagePersister.stampRichContentVerdict. Reusing any pre-run
        // regardless of its string stores these wrong answers.
        let personalRow = try await createRow(
            makeProcessedMessage(
                id: uniqueID("prerun-mismatch-personal"),
                html: RichVerdictFixture.personalHTML,
                prerun: RichContentPrerun(html: RichVerdictFixture.personalHTML + "\n", isRich: true)
            ),
            using: persister
        )
        XCTAssertEqual(personalRow.verdict, .notRich)

        let richRow = try await createRow(
            makeProcessedMessage(
                id: uniqueID("prerun-mismatch-rich"),
                html: RichVerdictFixture.richHTML,
                prerun: RichContentPrerun(html: RichVerdictFixture.richHTML + "\n", isRich: false)
            ),
            using: persister
        )
        XCTAssertEqual(richRow.verdict, .rich)
    }

    func testCreateNewMessage_withoutPrerun_classifiesTheSavedHTML() async throws {
        let persister = makePersister()

        // A hand-built value, as a caller that bypasses `prepareMessage`
        // passes: nil means "not pre-computed", never "not rich".
        //
        // Revert-check: the classifier fallback in
        // MessagePersister.stampRichContentVerdict's `classify` closure.
        // Reading a missing pre-run as "not rich" fails the rich row.
        let richRow = try await createRow(
            makeProcessedMessage(id: uniqueID("no-prerun-rich"), html: RichVerdictFixture.richHTML),
            using: persister
        )
        XCTAssertEqual(richRow.verdict, .rich)

        let personalRow = try await createRow(
            makeProcessedMessage(id: uniqueID("no-prerun-personal"), html: RichVerdictFixture.personalHTML),
            using: persister
        )
        XCTAssertEqual(personalRow.verdict, .notRich)
    }

    func testRichContentPrerun_ownRowNoHTMLOrFallbackTextBody_returnsNil() {
        // Control: an ordinary received HTML row is pre-run, on `storedHTML`.
        let received = makeProcessedMessage(id: "prerun-control", html: RichVerdictFixture.richHTML)
        XCTAssertEqual(
            MessagePersister.richContentPrerun(for: received),
            RichContentPrerun(html: RichVerdictFixture.richHTML, isRich: true)
        )

        // Revert-check: the guard clauses of
        // MessagePersister.richContentPrerun(for:), one assertion each.
        //
        // HONEST SCOPE: the pre-run is an optimisation, so dropping a clause
        // costs a wasted DOM cleanup rather than a wrong stored verdict. Only
        // this direct call can see the difference.
        let own = makeProcessedMessage(id: "prerun-own", isFromMe: true, html: RichVerdictFixture.richHTML)
        XCTAssertNil(MessagePersister.richContentPrerun(for: own))

        let noHTML = makeProcessedMessage(id: "prerun-no-html", html: nil)
        XCTAssertNil(MessagePersister.richContentPrerun(for: noHTML))

        let fallbackBody = makeProcessedMessage(
            id: "prerun-fallback-body",
            html: RichVerdictFixture.richHTML,
            plainText: RichVerdictFixture.newsletterFallbackText
        )
        XCTAssertNil(MessagePersister.richContentPrerun(for: fallbackBody))

        // With no body the snippet stands in for it, as in the resolver.
        let fallbackSnippet = makeProcessedMessage(
            id: "prerun-fallback-snippet",
            html: RichVerdictFixture.richHTML,
            plainText: nil,
            snippet: RichVerdictFixture.newsletterFallbackText
        )
        XCTAssertNil(MessagePersister.richContentPrerun(for: fallbackSnippet))
    }

    func testCreateNewMessage_fallbackTextBodySkippedByThePrerun_stillStampsRich() async throws {
        let id = uniqueID("fallback-create")
        // HTML the classifier calls not rich, so only the fallback-text term
        // can make this row rich.
        var processed = makeProcessedMessage(
            id: id,
            html: RichVerdictFixture.personalHTML,
            plainText: RichVerdictFixture.newsletterFallbackText
        )
        processed.richContentPrerun = MessagePersister.richContentPrerun(for: processed)
        XCTAssertNil(processed.richContentPrerun)

        let row = try await createRow(processed, using: makePersister())

        // Revert-check: MessagePersister.stampRichContentVerdict evaluating
        // RichContentVerdictResolver.verdict (its fallback-text term) rather
        // than the classifier alone, which would store not rich here.
        XCTAssertNotNil(row.inputs.bodyStorageURI)
        XCTAssertEqual(row.verdict, .rich)
    }

    // MARK: - Failed save

    func testCreateNewMessage_failedHTMLSave_doesNotStampFromTheInHandHTML() async throws {
        let id = uniqueID("failed-save-create")
        let persister = makePersister(saveHTML: { _, _ in nil })

        let row = try await createRow(
            makeProcessedMessage(
                id: id,
                html: RichVerdictFixture.richHTML,
                prerun: RichContentPrerun(html: RichVerdictFixture.richHTML, isRich: true)
            ),
            using: persister
        )

        // The stored state has no HTML at all: no URI, no file, a plain body.
        XCTAssertNil(row.inputs.bodyStorageURI)
        XCTAssertFalse(handler.htmlFileExists(for: id))

        // Revert-check: `savedHTML: savedBodyStorageURI == nil ? nil :
        // canonicalHTML` in MessagePersister+Creation.swift. Passing the
        // in-hand string after a failed save stores `.rich` for a row that
        // has nothing to render as a card.
        XCTAssertEqual(row.verdict, .notRich)
    }

    func testCreateNewMessage_failedHTMLSaveOverAnEarlierFile_stampsFromTheStoredFile() async throws {
        let id = uniqueID("failed-save-earlier-file")
        // An earlier attempt left this message's file behind.
        XCTAssertNotNil(handler.saveHTML(RichVerdictFixture.richHTML, for: id))
        let persister = makePersister(saveHTML: { _, _ in nil })

        let row = try await createRow(
            makeProcessedMessage(
                id: id,
                html: RichVerdictFixture.personalHTML,
                prerun: RichContentPrerun(html: RichVerdictFixture.personalHTML, isRich: false)
            ),
            using: persister
        )

        // Revert-check: same guard as above, from the other side. A failed
        // save does not prove no HTML is stored; vouching for the in-hand
        // string stores `.notRich` over a rich file the bubble will load.
        XCTAssertNil(row.inputs.bodyStorageURI)
        XCTAssertEqual(row.verdict, .rich)
    }

    func testUpdateExistingMessage_failedHTMLSave_doesNotStampFromTheInHandHTML() async throws {
        let id = uniqueID("failed-save-update")
        let persister = makePersister(saveHTML: { _, _ in nil })
        _ = try await createRow(makeProcessedMessage(id: id, html: nil), using: persister)
        // Unknown opens the re-stamp gate without any input changing, so the
        // assertion below is on a verdict this update wrote.
        try await overwriteRawVerdict(0, forMessageID: id)

        let row = try await updateRow(
            makeProcessedMessage(
                id: id,
                html: RichVerdictFixture.richHTML,
                prerun: RichContentPrerun(html: RichVerdictFixture.richHTML, isRich: true)
            ),
            using: persister
        )

        // Revert-check: `savedHTML: savedBodyStorageURI == nil ? nil :
        // canonicalHTML` in MessagePersister+Updates.swift. Passing the
        // in-hand string stores `.rich`.
        XCTAssertNil(row.inputs.bodyStorageURI)
        XCTAssertEqual(row.verdict, .notRich)
    }

    // MARK: - Update path

    func testSaveMessage_existingRowRefetchedWithDifferentHTML_restampsInBothDirections() async throws {
        let id = uniqueID("refetch-html")
        let persister = makePersister()
        let richVersion = makeGmailMessage(id: id, html: RichVerdictFixture.richHTML)
        let personalVersion = makeGmailMessage(id: id, html: RichVerdictFixture.personalHTML)

        try await persist(richVersion, using: persister)
        let created = try await storedRow(id: id)
        XCTAssertEqual(created.verdict, .rich)

        // Revert-check: the `savedBodyStorageURI != nil` term of the re-stamp
        // gate in MessagePersister+Updates.swift. Only the file's contents
        // change between versions (the inputs guard below), so without that
        // term the row keeps the verdict of HTML it no longer stores.
        try await persist(personalVersion, using: persister)
        let refetchedPersonal = try await storedRow(id: id)
        XCTAssertEqual(refetchedPersonal.inputs, created.inputs)
        XCTAssertEqual(refetchedPersonal.verdict, .notRich)

        try await persist(richVersion, using: persister)
        let refetchedRich = try await storedRow(id: id)
        XCTAssertEqual(refetchedRich.inputs, created.inputs)
        XCTAssertEqual(refetchedRich.verdict, .rich)
    }

    func testUpdateExistingMessage_bodyTextBecomesFallbackTextWithoutIncomingHTML_restampsRich() async throws {
        let id = uniqueID("update-fallback-body")
        let persister = makePersister()
        let created = try await createRow(
            makeProcessedMessage(id: id, html: RichVerdictFixture.personalHTML),
            using: persister
        )
        XCTAssertEqual(created.verdict, .notRich)
        XCTAssertNotNil(created.inputs.bodyStorageURI)

        let updated = try await updateRow(
            makeProcessedMessage(
                id: id,
                html: nil,
                plainText: RichVerdictFixture.newsletterFallbackText
            ),
            using: persister
        )

        // Revert-check: the `bodyText != previousBodyText` term of
        // `verdictInputsChanged` in MessagePersister+Updates.swift. This
        // update saved no HTML, so without that term the row stays "not rich"
        // and the bubble shows its text before swapping to a card.
        XCTAssertEqual(updated.inputs.bodyText, RichVerdictFixture.newsletterFallbackText)
        XCTAssertEqual(updated.inputs.bodyStorageURI, created.inputs.bodyStorageURI)
        XCTAssertEqual(updated.inputs.snippet, created.inputs.snippet)
        XCTAssertEqual(updated.verdict, .rich)
    }

    func testUpdateExistingMessage_snippetBecomesFallbackTextWithoutIncomingHTML_restampsRich() async throws {
        let id = uniqueID("update-fallback-snippet")
        let persister = makePersister()
        let created = try await createRow(
            makeProcessedMessage(id: id, html: RichVerdictFixture.personalHTML, plainText: nil),
            using: persister
        )
        // The snippet only stands in for a body that is nil.
        XCTAssertNil(created.inputs.bodyText)
        XCTAssertEqual(created.verdict, .notRich)

        let updated = try await updateRow(
            makeProcessedMessage(
                id: id,
                html: nil,
                plainText: nil,
                snippet: RichVerdictFixture.newsletterFallbackText
            ),
            using: persister
        )

        // Revert-check: the `snippet != previousSnippet` term of
        // `verdictInputsChanged` in MessagePersister+Updates.swift.
        XCTAssertNil(updated.inputs.bodyText)
        XCTAssertEqual(updated.inputs.snippet, RichVerdictFixture.newsletterFallbackText)
        XCTAssertEqual(updated.inputs.bodyStorageURI, created.inputs.bodyStorageURI)
        XCTAssertEqual(updated.verdict, .rich)
    }

    func testUpdateExistingMessage_isFromMeFlipsWithoutIncomingHTML_restampsInBothDirections() async throws {
        let persister = makePersister()

        // Revert-check: the `isFromMe != previousIsFromMe` term of
        // `verdictInputsChanged` in MessagePersister+Updates.swift. Each
        // update below saves no HTML and changes no text, so without that
        // term both rows keep the verdict of the other direction.

        // Received, then recognised as an own alias by a later fetch.
        let receivedID = uniqueID("flip-to-own")
        let received = try await createRow(
            makeProcessedMessage(id: receivedID, html: RichVerdictFixture.richHTML),
            using: persister
        )
        XCTAssertEqual(received.verdict, .rich)
        let nowOwn = try await updateRow(
            makeProcessedMessage(id: receivedID, isFromMe: true, html: nil),
            using: persister
        )
        XCTAssertTrue(nowOwn.inputs.isFromMe)
        assertStoredContentUnchanged(from: received, to: nowOwn)
        XCTAssertEqual(nowOwn.verdict, .notRich)

        // Own, then no longer an alias: the stored HTML is read back and
        // classified, since this update brought none.
        let ownID = uniqueID("flip-to-received")
        let own = try await createRow(
            makeProcessedMessage(id: ownID, isFromMe: true, html: RichVerdictFixture.richHTML),
            using: persister
        )
        XCTAssertEqual(own.verdict, .notRich)
        let nowReceived = try await updateRow(
            makeProcessedMessage(id: ownID, isFromMe: false, html: nil),
            using: persister
        )
        XCTAssertFalse(nowReceived.inputs.isFromMe)
        assertStoredContentUnchanged(from: own, to: nowReceived)
        XCTAssertEqual(nowReceived.verdict, .rich)
    }

    func testUpdateExistingMessage_unknownVerdictAndNoInputChange_stampsFromTheStoredHTML() async throws {
        let id = uniqueID("update-unknown")
        let persister = makePersister()
        let created = try await createRow(
            makeProcessedMessage(id: id, html: RichVerdictFixture.richHTML),
            using: persister
        )
        // A row persisted before verdicts existed, or under an older epoch.
        try await overwriteRawVerdict(0, forMessageID: id)
        let legacy = try await storedRow(id: id)
        XCTAssertEqual(legacy.verdict, .unknown)

        let updated = try await updateRow(makeProcessedMessage(id: id, html: nil), using: persister)

        // Revert-check: the `storedRichContentVerdict == .unknown` term of
        // the re-stamp gate in MessagePersister+Updates.swift. No HTML was
        // saved and no input changed (the guard below), so nothing else opens
        // the gate and the row would stay unknown.
        XCTAssertEqual(updated.inputs, created.inputs)
        XCTAssertEqual(updated.verdict, .rich)
    }

    func testUpdateExistingMessage_htmlStorageClosedDuringRestamp_stampsUnknownNotThePreviousVerdict() async throws {
        let id = uniqueID("update-closed-storage")
        let persister = makePersister()
        let created = try await createRow(
            makeProcessedMessage(id: id, html: RichVerdictFixture.richHTML),
            using: persister
        )
        XCTAssertEqual(created.verdict, .rich)

        // Only this suite's isolated directory closes; every read through the
        // handler now answers "absent", as it does during an account teardown.
        handler.closeAccountWork()

        let updated = try await updateRow(
            makeProcessedMessage(id: id, html: nil, plainText: RichVerdictFixture.editedPlainBody),
            using: persister
        )

        // Revert-check: MessagePersister.stampRichContentVerdict assigning
        // the resolver's `.unknown` instead of keeping the previous value.
        // This update changed the inputs, so a kept `.rich` would be rendered
        // as known for state nobody evaluated.
        XCTAssertEqual(updated.inputs.bodyText, RichVerdictFixture.editedPlainBody)
        XCTAssertEqual(updated.verdict, .unknown)
        XCTAssertEqual(updated.rawVerdict, 0)
    }

    // MARK: - Helpers

    private func uniqueID(_ label: String) -> String {
        "rich-verdict-\(label)-\(UUID().uuidString)"
    }

    /// A persister whose default `saveHTML` writes through the isolated
    /// handler. Pass `saveHTML` to simulate a failed write.
    private func makePersister(
        saveHTML: ((String, String) -> URL?)? = nil
    ) -> MessagePersister {
        MessagePersister(
            coreDataStack: coreDataStack,
            htmlContentHandler: handler,
            saveHTML: saveHTML,
            photoPrefetcher: { _ in },
            inlineCIDPrefetchScheduler: { _, _ in }
        )
    }

    /// A multipart/alternative message for the real `MessageProcessor`. The
    /// plain part and snippet are the same for every HTML, so two versions of
    /// one id differ only in the HTML file they store.
    private func makeGmailMessage(id: String, fromMe: Bool = false, html: String) -> GmailMessage {
        let builder = GmailMessageBuilder()
            .withId(id)
            .withThreadId("thread-\(id)")
            .withSubject("Statement ready")
            .withSnippet(RichVerdictFixture.snippet)
            .withInternalDateMillis(1_700_000_000_000)
            .withBodyText(RichVerdictFixture.plainBody)
            .withBodyHtml(html)
        if fromMe {
            return builder
                .withLabels(["SENT"])
                .withFrom(RichVerdictFixture.myEmail, name: "Me")
                .withTo([RichVerdictFixture.senderEmail])
                .build()
        }
        return builder
            .withLabels(["INBOX"])
            .withFrom(RichVerdictFixture.senderEmail, name: "Example Bank")
            .withTo([RichVerdictFixture.myEmail])
            .build()
    }

    /// A hand-built processed message, as a stub processor returns: no
    /// canonical content, so `storedHTML` is `html` exactly, and no pre-run
    /// unless one is passed. The From/To headers stay fixed while `isFromMe`
    /// varies, which is how a changed alias set looks to an update.
    private func makeProcessedMessage(
        id: String,
        isFromMe: Bool = false,
        html: String?,
        plainText: String? = RichVerdictFixture.plainBody,
        snippet: String = RichVerdictFixture.snippet,
        prerun: RichContentPrerun? = nil
    ) -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = "Statement ready"
        headers.from = "Example Bank <\(RichVerdictFixture.senderEmail)>"
        headers.to = [EmailAddress(email: RichVerdictFixture.myEmail, displayName: nil)]
        headers.isFromMe = isFromMe

        var processed = ProcessedMessage()
        processed.id = id
        processed.gmThreadId = "thread-\(id)"
        processed.snippet = snippet
        processed.cleanedSnippet = snippet
        processed.internalDate = Date(timeIntervalSince1970: 1_700_000_000)
        processed.headers = headers
        processed.htmlBody = html
        processed.plainTextBody = plainText
        processed.labelIds = ["INBOX"]
        processed.richContentPrerun = prerun
        return processed
    }

    /// Runs the full pipeline (prepare, then create or update) in its own
    /// context and commits it, as one sync save point does.
    private func persist(_ gmailMessage: GmailMessage, using persister: MessagePersister) async throws {
        let context = testStack.newBackgroundContext()
        let disposition = try await persister.saveMessage(
            gmailMessage,
            myAliases: RichVerdictFixture.myAliases,
            in: context
        )
        XCTAssertEqual(disposition, .persisted)
        try await commit(context)
    }

    private func createRow(
        _ processedMessage: ProcessedMessage,
        using persister: MessagePersister
    ) async throws -> StoredVerdictRow {
        let context = testStack.newBackgroundContext()
        try await persister.createNewMessage(
            processedMessage,
            labelIds: nil,
            myAliases: RichVerdictFixture.myAliases,
            in: context
        )
        try await commit(context)
        return try await storedRow(id: processedMessage.id)
    }

    private func updateRow(
        _ processedMessage: ProcessedMessage,
        using persister: MessagePersister
    ) async throws -> StoredVerdictRow {
        let context = testStack.newBackgroundContext()
        let didUpdate = await persister.updateExistingMessage(
            processedMessage,
            labelIds: nil,
            in: context
        )
        XCTAssertTrue(didUpdate, "The row must already be stored for an update")
        try await commit(context)
        return try await storedRow(id: processedMessage.id)
    }

    /// The persister stages into the caller's context and never saves it.
    private func commit(_ context: NSManagedObjectContext) async throws {
        try await context.perform {
            guard context.hasChanges else { return }
            try context.save()
        }
    }

    /// Reads the committed row through a context that never saw the write.
    private func storedRow(
        id: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> StoredVerdictRow {
        let readContext = testStack.newBackgroundContext()
        let row = try await readContext.perform { () throws -> StoredVerdictRow? in
            let request: NSFetchRequest<Message> = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            guard let message = try readContext.fetch(request).first else { return nil }
            return StoredVerdictRow(
                rawVerdict: message.richContentVerdict,
                verdict: message.storedRichContentVerdict,
                inputs: message.richContentVerdictInputs
            )
        }
        return try XCTUnwrap(row, "No committed row for \(id)", file: file, line: line)
    }

    private func overwriteRawVerdict(_ rawValue: Int16, forMessageID id: String) async throws {
        let context = testStack.newBackgroundContext()
        try await context.perform {
            let request: NSFetchRequest<Message> = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            let message = try XCTUnwrap(context.fetch(request).first)
            message.richContentVerdict = rawValue
            try context.save()
        }
    }

    /// Fixture guard for an update meant to change `isFromMe` alone: the
    /// rest of what the verdict reads is as it was.
    private func assertStoredContentUnchanged(
        from before: StoredVerdictRow,
        to after: StoredVerdictRow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after.inputs.bodyText, before.inputs.bodyText, file: file, line: line)
        XCTAssertEqual(after.inputs.snippet, before.inputs.snippet, file: file, line: line)
        XCTAssertEqual(after.inputs.bodyStorageURI, before.inputs.bodyStorageURI, file: file, line: line)
    }
}

/// What a committed row holds: its verdict, raw and decoded, and the stored
/// state the verdict is a function of.
private struct StoredVerdictRow: Sendable {
    let rawVerdict: Int16
    let verdict: RichContentVerdict
    let inputs: RichContentVerdictInputs
}

private enum RichVerdictFixture {
    static let myEmail = "me@example.com"
    static let senderEmail = "statements@examplebank.com"
    static let myAliases: Set<String> = [normalizedEmail("me@example.com")]

    static let snippet = "Statement ready"
    static let plainBody = "Your monthly account statement is now available."
    static let editedPlainBody = "Your corrected monthly account statement is now available."

    /// A transactional template. The classifier calls it rich.
    static let richHTML = """
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

    /// A person-to-person message in Gmail's div wrapper. Not rich.
    static let personalHTML = "<div dir=\"ltr\">Thanks, got it. See you at lunch tomorrow.</div>"

    /// A newsletter's plain-text alternative: a marker phrase and two link
    /// lines, which `NewsletterFallbackText.looksLikeFallbackText` requires.
    static let newsletterFallbackText = """
    View in browser: https://example.com/view
    Tickets are now on sale for the Spring Documentary Festival.
    Unsubscribe: https://example.com/unsubscribe
    """
}
