import XCTest
import CoreData
@testable import esc_chatmail

/// Ingest stamps `Message.richContentVerdict`; the bubble load publishes a
/// verdict for the mapped row. A bubble routes on the stored one at mount, so
/// a row where the two differ renders text and then swaps to a card (or the
/// reverse) on every open. This suite runs both ends against one store and one
/// HTML directory: the real `MessageProcessor` and `MessagePersister` going in,
/// the real `ChatMessageRowModelMapper` and `MessageBubbleLoader` coming out.
///
/// HONEST SCOPE: ingest and the loader both evaluate
/// `RichContentVerdictResolver`, so that the classifier gives one HTML string
/// one answer on both sides holds by construction, and no change to the
/// classifier or the resolver's rule can fail here. What this suite pins is
/// the part that is not shared: that ingest stamps at all (create and update
/// paths), that the stored-state inputs ingest stamps from are the ones the
/// loader reads back through the row model, and that the pre-run is reused
/// only for the string it was computed on.
final class RichContentVerdictIngestLoaderEquivalenceTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var messagesDirectory: URL!
    private var handler: HTMLContentHandler!

    private static let myEmail = "me@example.com"
    private static let baseInternalDateMillis = 1_704_067_200_000

    /// Reads as neither newsletter fallback text nor a quote or signature, so
    /// it survives as the stored preview of a row whose HTML derives none and
    /// never decides a verdict by itself.
    private static let neutralSnippet = "Quarterly planning notes are ready for review."
    private static let refetchedSnippet = "The refetched copy of the planning notes."

    /// Short div-wrapped personal text: not rich whatever the cleanup keeps.
    private static let personalHTML =
        #"<div dir="ltr">The notes from the planning call are in the folder we talked about.</div><div dir="ltr">Can you take a look before Thursday?</div>"#

    /// The golden corpus's `simple_div_transactional_alert_with_links_is_rich`
    /// input, which `GoldenCorpusReplayTests` pins as rich. Its text carries no
    /// newsletter marker, so the classifier decides its verdict, not the
    /// fallback-text term.
    private static let richAlertHTML =
        #"<div dir="ltr">Security alert for your account<div><br></div><div>We detected a new sign-in to your account from Chrome on macOS. If this wasn't you, secure your account immediately.</div><div><br></div><div><a href="https://example.com/review">Review activity</a> | <a href="https://example.com/help">Get help</a></div><div><br></div><div>This is a service message about your account security. Please do not reply to this message.</div></div>"#

    /// A newsletter's text alternative: a marker word and two URL lines, which
    /// is what `NewsletterFallbackText.looksLikeFallbackText` keys on.
    private static let newsletterFallbackPlainText = """
        Your weekly digest is ready.
        https://example.com/digest

        Unsubscribe
        https://example.com/unsubscribe
        """

    override func setUp() async throws {
        try await super.setUp()
        stack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichVerdictEquivalence-\(UUID().uuidString)", isDirectory: true)
        handler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        await ModificationTracker.shared.reset()
    }

    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        handler = nil
        if let directory = messagesDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        messagesDirectory = nil
        coreDataStack = nil
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Golden corpus

    /// Revert-check: delete the `stampRichContentVerdict` call in
    /// `MessagePersister.createNewMessage` and every row stays `.unknown`, with
    /// each load asking for a refresh. Make
    /// `MessagePersister.richContentPrerun(for:)` return a wrong `isRich` for
    /// `storedHTML` (a constant, say) and the reused answer contradicts the
    /// load on every row the classifier decides the other way.
    ///
    /// HONEST SCOPE: making `richContentPrerun(for:)` return nil always passes.
    /// It is an optimisation: the stamp then classifies for itself.
    @MainActor
    func testGoldenCorpus_ingestStoredVerdict_equalsLoaderPublishedVerdict() async throws {
        let corpus = try loadCorpus()
        var fixtures: [VerdictEquivalenceFixture] = []
        for scenario in corpus.htmlToBubbleTextCases {
            fixtures.append(VerdictEquivalenceFixture(
                section: .htmlToBubbleText,
                caseID: scenario.id,
                html: scenario.inputHTML,
                plainText: nil,
                expectedIsRich: nil
            ))
        }
        for scenario in corpus.richHTMLDetectionCases {
            fixtures.append(VerdictEquivalenceFixture(
                section: .richHTMLDetection,
                caseID: scenario.id,
                html: scenario.inputHTML,
                plainText: nil,
                expectedIsRich: scenario.expectedHasRichHTMLContent
            ))
        }
        for scenario in corpus.rawSourceHTMLRecoveryCases {
            // Raw source arrives as a textual body; ingest salvages the
            // embedded HTML part out of it and stores that.
            fixtures.append(VerdictEquivalenceFixture(
                section: .rawSourceHTMLRecovery,
                caseID: scenario.id,
                html: nil,
                plainText: scenario.input,
                expectedIsRich: nil
            ))
        }
        // A section that decoded empty would make its part of the loop vacuous.
        for section in VerdictEquivalenceCorpusSection.allCases {
            XCTAssertFalse(
                fixtures.filter { $0.section == section }.isEmpty,
                "Golden corpus section \(section.rawValue) is empty"
            )
        }
        XCTAssertEqual(
            Set(corpus.richHTMLDetectionCases.map(\.expectedHasRichHTMLContent)),
            [true, false],
            "The rich-detection section must pin both verdicts, or a constant stamp could pass it"
        )

        // Chronological, as saveMessages' callers pass them.
        let messages = fixtures.enumerated().map { index, fixture in
            makeMessage(
                id: fixture.messageID,
                html: fixture.html,
                plainText: fixture.plainText,
                internalDateMillis: Self.baseInternalDateMillis + index * 1_000
            )
        }
        let syncContext = coreDataStack.newBackgroundContext()
        try await persist(messages, using: makePersister(), in: syncContext)

        let rows = try fetchRows(ids: fixtures.map(\.messageID))
        XCTAssertEqual(rows.count, fixtures.count)
        let harness = makeLoaderHarness()
        var comparedCounts: [VerdictEquivalenceCorpusSection: Int] = [:]
        for fixture in fixtures {
            let label = "\(fixture.section.rawValue):\(fixture.caseID)"
            guard let persisted = rows[fixture.messageID] else {
                XCTFail("\(label): no persisted row")
                continue
            }
            // The load publishes the stored rule only on its stored-preview
            // branch. Every corpus message is built to land there (received,
            // not a forward, and the fixed snippet backs the preview), so a
            // row outside it is a fixture defect and must not pass as skipped.
            guard Self.loadPublishesStoredRule(for: persisted.row) else {
                let isFromMe = persisted.row.isFromMe
                let isForward = persisted.row.isForwardedEmail
                let hasPreview = MessagePreviewText.nonEmpty(persisted.row.chatPreviewText) != nil
                XCTFail("\(label): outside the compared population (own=\(isFromMe), forward=\(isForward), preview=\(hasPreview))")
                continue
            }

            let published = await loadAndAssertEquivalence(persisted, harness: harness, label)
            // A row whose stored text may carry a shared-document link is still
            // compared stored against published above, but reports no known
            // verdict at mount (`ChatMessageRowModelMapper.knownRichContentVerdict`).
            // No corpus case mentions such a host today; without this a future
            // one would fail here although nothing disagrees.
            let mayCarryLink = SharedDocumentLinkExtractor.mayContainLinks(
                in: [persisted.row.chatPreviewText, persisted.row.bodyText, persisted.row.snippet]
            )
            let expectedKnown: Bool? = mayCarryLink ? nil : published
            XCTAssertEqual(
                persisted.row.knownRichContentVerdict,
                expectedKnown,
                "\(label): the verdict the bubble routes on at mount differs from the one its load publishes (mayCarrySharedDocumentLink=\(mayCarryLink))"
            )
            if let expectedIsRich = fixture.expectedIsRich {
                XCTAssertEqual(
                    persisted.stored,
                    RichContentVerdict(isRich: expectedIsRich),
                    "\(label): ingest stored a verdict other than the corpus expectation shared with web"
                )
            }
            comparedCounts[fixture.section, default: 0] += 1
        }

        XCTAssertEqual(comparedCounts[.htmlToBubbleText, default: 0], corpus.htmlToBubbleTextCases.count)
        XCTAssertEqual(comparedCounts[.richHTMLDetection, default: 0], corpus.richHTMLDetectionCases.count)
        XCTAssertEqual(comparedCounts[.rawSourceHTMLRecovery, default: 0], corpus.rawSourceHTMLRecoveryCases.count)
        XCTAssertTrue(
            harness.refresher.scheduledMessageIDs.isEmpty,
            "A scheduled refresh means a load disagreed with the verdict ingest stored"
        )
    }

    // MARK: - Hand-built rows the corpus never exercises

    /// The corpus HTML sections never pair a non-rich HTML part with a
    /// newsletter-style text part, the one shape where the fallback-text term
    /// decides the verdict and the classifier is not consulted.
    ///
    /// Revert-check: move the `stampRichContentVerdict` call in
    /// `MessagePersister.createNewMessage` above the `bodyText` assignment and
    /// ingest evaluates a row with no body text: it stores not-rich where the
    /// load, reading the stored body, publishes rich.
    @MainActor
    func testFallbackTextRow_nonRichHTMLWithNewsletterPlainText_storesRichMatchingLoader() async throws {
        XCTAssertFalse(
            RichContentClassifier.hasGenuineRichContentAfterCleanup(Self.personalHTML),
            "Precondition: the classifier alone must call this HTML not rich"
        )
        let id = uniqueMessageID("fallback-text")
        let syncContext = coreDataStack.newBackgroundContext()
        try await persist(
            [makeMessage(id: id, html: Self.personalHTML, plainText: Self.newsletterFallbackPlainText)],
            using: makePersister(),
            in: syncContext
        )

        let persisted = try fetchRow(id: id)
        XCTAssertTrue(
            NewsletterFallbackText.looksLikeFallbackText(persisted.row.bodyText),
            "Precondition: the stored body must read as newsletter fallback text"
        )
        XCTAssertFalse(
            NewsletterFallbackText.looksLikeFallbackText(persisted.row.snippet),
            "Precondition: only the body, not the snippet, may trip the fallback-text term"
        )
        XCTAssertTrue(Self.loadPublishesStoredRule(for: persisted.row))

        let published = await loadAndAssertEquivalence(persisted, harness: makeLoaderHarness(), "fallback-text")
        XCTAssertEqual(persisted.stored, .rich)
        XCTAssertTrue(published)
        XCTAssertEqual(persisted.row.knownRichContentVerdict, true)
    }

    /// The fallback text that makes the received row above rich must not make
    /// an own row rich: the load publishes not-rich for own rows before it
    /// evaluates anything.
    ///
    /// Revert-check: drop the own-row guards in
    /// `RichContentVerdictResolver.verdict` and `cheapTerms`, or have
    /// `Message.richContentVerdictInputs` report `isFromMe` as false: the
    /// fallback text then stamps this own row rich while the load publishes
    /// not-rich.
    @MainActor
    func testFallbackTextRow_sentFromMe_storesNotRichMatchingLoader() async throws {
        let id = uniqueMessageID("fallback-text-own")
        let syncContext = coreDataStack.newBackgroundContext()
        try await persist(
            [makeMessage(
                id: id,
                html: Self.personalHTML,
                plainText: Self.newsletterFallbackPlainText,
                isFromMe: true
            )],
            using: makePersister(),
            in: syncContext
        )

        let persisted = try fetchRow(id: id)
        XCTAssertTrue(persisted.row.isFromMe, "Precondition: the row must be an own row")
        XCTAssertTrue(
            NewsletterFallbackText.looksLikeFallbackText(persisted.row.bodyText),
            "Precondition: the same fallback text that made the received row rich"
        )

        let published = await loadAndAssertEquivalence(persisted, harness: makeLoaderHarness(), "fallback-text-own")
        XCTAssertEqual(persisted.stored, .notRich)
        XCTAssertFalse(published)
        XCTAssertNil(persisted.row.knownRichContentVerdict, "An own row's stored verdict never reaches the view")
    }

    /// A row with attachments makes the load build its HTML analysis from the
    /// canonical content (`canonicalContentForAnalysisIfNeeded`), a branch no
    /// corpus message reaches.
    ///
    /// Revert-check: delete the `stampRichContentVerdict` call in
    /// `MessagePersister.createNewMessage`.
    ///
    /// HONEST SCOPE: the HTML is on disk, so the analysis and the stored state
    /// agree that the row has an HTML source. A load that took that term from
    /// the analysis again, as it did before verdicts were stored, passes here.
    @MainActor
    func testAttachmentRow_canonicalLoadBranch_storedVerdictMatchesLoader() async throws {
        let id = uniqueMessageID("attachment")
        let attachment = MessagePart(
            partId: "1",
            mimeType: "application/pdf",
            filename: "report.pdf",
            headers: [
                MessageHeader(name: "Content-Disposition", value: "attachment; filename=\"report.pdf\"")
            ],
            body: MessageBody(size: 2_048, data: nil, attachmentId: "att-\(UUID().uuidString)"),
            parts: nil
        )
        let syncContext = coreDataStack.newBackgroundContext()
        try await persist(
            [makeMessage(id: id, html: Self.richAlertHTML, attachment: attachment)],
            using: makePersister(),
            in: syncContext
        )

        let persisted = try fetchRow(id: id)
        let request = persisted.row.makeContentRequest()
        XCTAssertTrue(request.hasAttachments, "Precondition: the canonical-load branch needs an attachment-bearing row")
        XCTAssertFalse(request.attachmentSnapshots.isEmpty)
        XCTAssertTrue(Self.loadPublishesStoredRule(for: persisted.row))

        let published = await loadAndAssertEquivalence(persisted, harness: makeLoaderHarness(), "attachment")
        XCTAssertEqual(persisted.stored, .rich)
        XCTAssertTrue(published)
        XCTAssertEqual(persisted.row.knownRichContentVerdict, true)
    }

    /// Revert-check: delete the `stampRichContentVerdict` call in
    /// `MessagePersister.performExistingMessageUpdate` and the refetched row
    /// keeps the not-rich verdict of the HTML it replaced, while its load
    /// classifies the new file rich.
    ///
    /// HONEST SCOPE: this update saves the incoming HTML, so the pre-run is
    /// reused for the very string it classified. The reuse guard is pinned by
    /// `testUpdatePath_failedHTMLSave_doesNotReusePrerunForStaleStoredHTML`.
    @MainActor
    func testUpdatePath_refetchWithDifferentHTML_restampsToMatchLoader() async throws {
        let id = uniqueMessageID("update")
        let persister = makePersister()
        let syncContext = coreDataStack.newBackgroundContext()

        try await persist([makeMessage(id: id, html: Self.personalHTML)], using: persister, in: syncContext)
        let created = try fetchRow(id: id)
        let createdVerdict = await loadAndAssertEquivalence(created, harness: makeLoaderHarness(), "update:created")
        XCTAssertEqual(created.stored, .notRich)
        XCTAssertFalse(createdVerdict)

        try await persist(
            [makeMessage(id: id, html: Self.richAlertHTML, snippet: Self.refetchedSnippet)],
            using: persister,
            in: syncContext
        )
        XCTAssertEqual(
            handler.loadHTML(for: id),
            Self.richAlertHTML,
            "Precondition: the refetch must have replaced the stored HTML"
        )

        // A fresh loader, so nothing memoized for the replaced HTML answers.
        let updated = try fetchRow(id: id)
        let updatedVerdict = await loadAndAssertEquivalence(updated, harness: makeLoaderHarness(), "update:refetched")
        XCTAssertEqual(updated.stored, .rich)
        XCTAssertTrue(updatedVerdict)
        XCTAssertEqual(updated.row.knownRichContentVerdict, true)
    }

    /// The pre-run is the classifier's answer for the incoming HTML. When the
    /// save of that HTML fails, the row keeps the file an earlier sync stored,
    /// and the stamp has to classify that file, as the load will.
    ///
    /// Revert-check: drop the `prerun.html == html` comparison in
    /// `MessagePersister.stampRichContentVerdict` (reuse `prerun.isRich`
    /// whenever a pre-run exists) and the row is stamped rich from HTML that
    /// was never stored, while its load classifies the stored file not rich.
    @MainActor
    func testUpdatePath_failedHTMLSave_doesNotReusePrerunForStaleStoredHTML() async throws {
        let id = uniqueMessageID("failed-save")
        let syncContext = coreDataStack.newBackgroundContext()
        try await persist([makeMessage(id: id, html: Self.personalHTML)], using: makePersister(), in: syncContext)

        let refetched = makeMessage(id: id, html: Self.richAlertHTML, snippet: Self.refetchedSnippet)
        let failingSavePersister = makePersister(saveHTML: { _, _ in nil })

        // Without a live pre-run for the incoming HTML the stamp classifies
        // for itself and the guard under test is never consulted.
        let prepared = try await failingSavePersister.prepareMessage(refetched, myAliases: [Self.myEmail])
        guard case .processed(let processed) = prepared else {
            return XCTFail("Precondition: the refetched message must process")
        }
        let prerun = try XCTUnwrap(
            processed.richContentPrerun,
            "Precondition: a received HTML row without fallback text must carry a pre-run"
        )
        XCTAssertEqual(prerun.html, processed.storedHTML, "The pre-run must be keyed to the string persistence saves")
        XCTAssertTrue(prerun.isRich, "Precondition: the incoming HTML must classify rich")

        try await persist([refetched], using: failingSavePersister, in: syncContext)

        XCTAssertEqual(
            handler.loadHTML(for: id),
            Self.personalHTML,
            "Precondition: the failed save must leave the earlier HTML stored"
        )
        let updated = try fetchRow(id: id)
        XCTAssertEqual(
            updated.row.snippet,
            Self.refetchedSnippet,
            "Precondition: the update must have rewritten a verdict input, or it never re-stamps"
        )

        let published = await loadAndAssertEquivalence(updated, harness: makeLoaderHarness(), "failed-save")
        XCTAssertEqual(updated.stored, .notRich)
        XCTAssertFalse(published)
    }

    // MARK: - Ingest

    private func uniqueMessageID(_ tag: String) -> String {
        "golden-verdict-\(tag)-\(UUID().uuidString)"
    }

    /// - Parameter saveHTML: nil keeps the persister's default, which writes
    ///   through `handler`.
    private func makePersister(saveHTML: ((String, String) -> URL?)? = nil) -> MessagePersister {
        let myEmail = Self.myEmail
        return MessagePersister(
            coreDataStack: coreDataStack,
            // No fixture has a body Gmail would return by attachment ID, so a
            // fetch means the fixture is wrong: fail the message, loudly.
            messageProcessor: MessageProcessor(fetchAttachmentData: { _, _ in
                throw URLError(.badServerResponse)
            }),
            htmlContentHandler: handler,
            saveHTML: saveHTML,
            conversationManager: ConversationManager(currentUserEmail: { myEmail }),
            photoPrefetcher: { _ in },
            inlineCIDPrefetchScheduler: { _, _ in }
        )
    }

    private func makeMessage(
        id: String,
        html: String?,
        plainText: String? = nil,
        isFromMe: Bool = false,
        snippet: String = RichContentVerdictIngestLoaderEquivalenceTests.neutralSnippet,
        internalDateMillis: Int = RichContentVerdictIngestLoaderEquivalenceTests.baseInternalDateMillis,
        attachment: MessagePart? = nil
    ) -> GmailMessage {
        // Gmail returns every body base64-encoded beside the part's own
        // headers. Naming the transfer encoding stops the processor sniffing
        // quoted-printable in text that merely contains "=3D", which would
        // rewrite the HTML before it is stored.
        func bodyPart(partId: String, mimeType: String, content: String) -> MessagePart {
            MessagePart(
                partId: partId,
                mimeType: mimeType,
                filename: nil,
                headers: [MessageHeader(name: "Content-Transfer-Encoding", value: "base64")],
                body: MessageBody(
                    size: content.utf8.count,
                    data: Data(content.utf8).base64EncodedString(),
                    attachmentId: nil
                ),
                parts: nil
            )
        }

        var bodyParts: [MessagePart] = []
        if let plainText {
            bodyParts.append(bodyPart(partId: "0.0", mimeType: "text/plain", content: plainText))
        }
        if let html {
            bodyParts.append(bodyPart(partId: "0.1", mimeType: "text/html", content: html))
        }

        // A subject that is neither a reply nor a forward, and a sender other
        // than the user, unless the row is meant to be an own row.
        let headers = [
            MessageHeader(
                name: "From",
                value: isFromMe ? "Me <\(Self.myEmail)>" : "Alice Sender <alice@example.com>"
            ),
            MessageHeader(name: "To", value: isFromMe ? "alice@example.com" : Self.myEmail),
            MessageHeader(name: "Subject", value: "Planning notes"),
            MessageHeader(name: "Message-ID", value: "<\(id)@verdict-equivalence.example.com>")
        ]
        let payload: MessagePart
        if let attachment {
            payload = MessagePart(
                partId: "",
                mimeType: "multipart/mixed",
                filename: nil,
                headers: headers,
                body: nil,
                parts: [
                    MessagePart(
                        partId: "0",
                        mimeType: "multipart/alternative",
                        filename: nil,
                        headers: nil,
                        body: nil,
                        parts: bodyParts
                    ),
                    attachment
                ]
            )
        } else {
            payload = MessagePart(
                partId: "",
                mimeType: "multipart/alternative",
                filename: nil,
                headers: headers,
                body: nil,
                parts: bodyParts
            )
        }

        return GmailMessage(
            id: id,
            threadId: "thread-\(id)",
            labelIds: isFromMe ? ["SENT"] : ["INBOX"],
            snippet: snippet,
            historyId: nil,
            internalDate: String(internalDateMillis),
            payload: payload,
            sizeEstimate: nil
        )
    }

    /// Persists through `saveMessages` and commits, as a sync run does.
    @MainActor
    private func persist(
        _ messages: [GmailMessage],
        using persister: MessagePersister,
        in syncContext: NSManagedObjectContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let report = try await persister.saveMessages(
            messages,
            myAliases: [Self.myEmail],
            in: syncContext
        )
        XCTAssertEqual(
            report.persistedIds,
            messages.map(\.id),
            "Every message must persist, in the order given",
            file: file,
            line: line
        )
        XCTAssertTrue(report.failedIds.isEmpty, "failed: \(report.failedIds)", file: file, line: line)
        XCTAssertTrue(
            report.unprocessableIds.isEmpty,
            "unprocessable: \(report.unprocessableIds)",
            file: file,
            line: line
        )
        XCTAssertTrue(report.excludedIds.isEmpty, "excluded: \(report.excludedIds)", file: file, line: line)
        try await coreDataStack.saveAsync(context: syncContext)
    }

    // MARK: - Read-back

    /// Reads the committed rows the way the chat screen does: on the main
    /// actor, through the row-model mapper.
    @MainActor
    private func fetchRows(ids: [String]) throws -> [String: VerdictEquivalencePersistedRow] {
        // A new main-queue context per read. It does not automerge, so one
        // reused across an update would hand back the row as first fetched.
        let viewContext = stack.makeMainQueueViewContext()
        let request: NSFetchRequest<Message> = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids)
        let messages = try viewContext.fetch(request)
        let rows = ChatMessageRowModelMapper.map(messages)

        var result: [String: VerdictEquivalencePersistedRow] = [:]
        for (message, row) in zip(messages, rows) {
            result[message.id] = VerdictEquivalencePersistedRow(
                stored: message.storedRichContentVerdict,
                inputs: message.richContentVerdictInputs,
                row: row
            )
        }
        return result
    }

    @MainActor
    private func fetchRow(id: String) throws -> VerdictEquivalencePersistedRow {
        let rows = try fetchRows(ids: [id])
        return try XCTUnwrap(rows[id], "No persisted row for \(id)")
    }

    /// Where `MessageBubbleLoader.loadContent` publishes the stored rule for a
    /// received row: its stored-preview branch. Forwards publish not-rich
    /// without classifying and blank previews take the compatibility path.
    private static func loadPublishesStoredRule(for row: ChatMessageRowModel) -> Bool {
        !row.isFromMe &&
            !row.isForwardedEmail &&
            MessagePreviewText.nonEmpty(row.chatPreviewText) != nil
    }

    private func makeLoaderHarness() -> VerdictEquivalenceLoaderHarness {
        let provider = ParsedEmailProvider()
        let recoverer = VerdictEquivalenceNoRecoveryService()
        let refresher = VerdictEquivalenceRecordingRefresher()
        let loader = MessageBubbleLoader(
            contactsResolver: VerdictEquivalenceNoContactsResolver(),
            htmlContentHandler: handler,
            htmlContentLoader: HTMLContentLoader(
                contentHandler: handler,
                parsedEmailProvider: provider,
                recoveryService: recoverer
            ),
            htmlContentRecoveryService: recoverer,
            htmlAnalysisCache: MessageBubbleHTMLAnalysisCache(),
            parsedEmailProvider: provider,
            renderedMessageCache: RenderedMessageCache(),
            richContentVerdictRefresher: refresher
        )
        return VerdictEquivalenceLoaderHarness(loader: loader, refresher: refresher)
    }

    /// Loads the row's content and asserts the verdict ingest stored is the
    /// one the load published. Returns the published verdict.
    @MainActor
    @discardableResult
    private func loadAndAssertEquivalence(
        _ persisted: VerdictEquivalencePersistedRow,
        harness: VerdictEquivalenceLoaderHarness,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let request = persisted.row.makeContentRequest()
        let result = await harness.loader.loadContent(from: request)

        // loadContent publishes the stored verdict when it could not compute
        // one, which would pass every comparison below without the load
        // having evaluated anything. Ask for the computed verdict as well.
        let accountContext = await harness.loader.captureAccountWorkContext()
        let computed: Bool?
        if let accountContext {
            computed = await harness.loader.loadRichContentClassification(
                from: request,
                accountContext: accountContext
            )
        } else {
            computed = nil
        }

        XCTAssertTrue(result.isComplete, "\(label): the load did not complete", file: file, line: line)
        XCTAssertNotEqual(
            persisted.stored,
            .unknown,
            "\(label): ingest left the row without a verdict",
            file: file,
            line: line
        )
        XCTAssertEqual(
            request.storedRichContentVerdict,
            persisted.stored,
            "\(label): the row model must carry the stored verdict to the load",
            file: file,
            line: line
        )
        XCTAssertEqual(
            request.richContentVerdictInputs,
            persisted.inputs,
            "\(label): the load must evaluate the stored state ingest stamped from",
            file: file,
            line: line
        )
        XCTAssertNotNil(computed, "\(label): the load could not evaluate the rule", file: file, line: line)
        XCTAssertEqual(
            computed,
            result.hasRichHTMLContent,
            "\(label): loadContent published something other than the computed verdict",
            file: file,
            line: line
        )
        XCTAssertEqual(
            persisted.stored.isRich,
            result.hasRichHTMLContent,
            "\(label): the stored verdict and the published verdict differ",
            file: file,
            line: line
        )
        XCTAssertFalse(
            harness.refresher.scheduledMessageIDs.contains(request.messageID),
            "\(label): the load asked for a refresh, so it disagreed with the stored verdict",
            file: file,
            line: line
        )
        return result.hasRichHTMLContent
    }

    // MARK: - Corpus loading

    private func loadCorpus() throws -> VerdictEquivalenceCorpus {
        // From the test bundle, as GoldenCorpusReplayTests loads it: the
        // compile-time source path is not readable from the simulator.
        let bundle = Bundle(for: type(of: self))
        guard let fixtureURL = bundle.url(forResource: "golden_message_corpus", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(VerdictEquivalenceCorpus.self, from: data)
    }
}

// MARK: - Corpus decoding

/// The three corpus sections that carry message bodies. Required keys, unlike
/// GoldenCorpusReplayTests' `decodeIfPresent`: a renamed section must fail the
/// decode rather than replay nothing.
private struct VerdictEquivalenceCorpus: Decodable {
    let htmlToBubbleTextCases: [VerdictEquivalenceHTMLCase]
    let richHTMLDetectionCases: [VerdictEquivalenceRichHTMLCase]
    let rawSourceHTMLRecoveryCases: [VerdictEquivalenceRawSourceCase]
}

private struct VerdictEquivalenceHTMLCase: Decodable {
    let id: String
    let inputHTML: String
}

private struct VerdictEquivalenceRichHTMLCase: Decodable {
    let id: String
    let inputHTML: String
    let expectedHasRichHTMLContent: Bool
}

private struct VerdictEquivalenceRawSourceCase: Decodable {
    let id: String
    let input: String
}

private enum VerdictEquivalenceCorpusSection: String, CaseIterable {
    case htmlToBubbleText
    case richHTMLDetection
    case rawSourceHTMLRecovery
}

private struct VerdictEquivalenceFixture {
    let section: VerdictEquivalenceCorpusSection
    let caseID: String
    let messageID: String
    let html: String?
    let plainText: String?
    /// The corpus's own expectation, where the section carries one for the
    /// stored HTML.
    let expectedIsRich: Bool?

    init(
        section: VerdictEquivalenceCorpusSection,
        caseID: String,
        html: String?,
        plainText: String?,
        expectedIsRich: Bool?
    ) {
        self.section = section
        self.caseID = caseID
        self.messageID = "golden-verdict-\(caseID)-\(UUID().uuidString)"
        self.html = html
        self.plainText = plainText
        self.expectedIsRich = expectedIsRich
    }
}

// MARK: - Read-back and loader doubles

private struct VerdictEquivalencePersistedRow {
    /// `Message.storedRichContentVerdict` as committed.
    let stored: RichContentVerdict
    /// `Message.richContentVerdictInputs`: what the persister stamped from.
    let inputs: RichContentVerdictInputs
    let row: ChatMessageRowModel
}

private struct VerdictEquivalenceLoaderHarness {
    let loader: MessageBubbleLoader
    let refresher: VerdictEquivalenceRecordingRefresher
}

/// Records the refreshes a load asks for instead of running them. The loader
/// schedules one only when its computed verdict differs from the stored one.
///
/// `@unchecked Sendable`: `lock` guards `messageIDs`.
private final class VerdictEquivalenceRecordingRefresher: RichContentVerdictRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var messageIDs: [String] = []

    func scheduleRefresh(messageID: String, handler: HTMLContentHandler) {
        lock.lock()
        messageIDs.append(messageID)
        lock.unlock()
    }

    var scheduledMessageIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messageIDs
    }
}

private struct VerdictEquivalenceNoRecoveryService: HTMLContentRecovering {
    func recoverHTMLContent(messageId: String) async -> String? {
        nil
    }
}

private struct VerdictEquivalenceNoContactsResolver: ContactsResolving {
    func ensureAuthorization() async throws {}

    func lookup(email: String) async -> ContactMatch? {
        nil
    }

    func prewarm(emails: [String]) async {}
}
