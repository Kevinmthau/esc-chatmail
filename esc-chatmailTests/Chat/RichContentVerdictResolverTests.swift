import XCTest
@testable import esc_chatmail

/// `RichContentVerdictResolver` over real files in an isolated Messages directory.
///
/// Each test gets its own UUID-named directory, and with it its own account boundary
/// (`HTMLContentHandler` keys the process-wide boundary by directory path), so closing
/// account work here closes nothing the shared handler or another test reads through. A
/// close does empty `HTMLContentHandler`'s process-wide in-memory caches, which costs other
/// tests a re-read from disk and nothing else.
///
/// Tests about which string is classified substitute the `classify` closure, so they do not
/// depend on `RichContentClassifier`'s heuristics. Tests that use the real classifier use
/// `RichContentVerdictResolverFixture.richHTML` (a `<section>`, which the classifier treats
/// as always rich; the same document `MessageBubbleLoaderTests` pins as rich) and
/// `plainHTML` (one paragraph: no tables, images, links or newsletter markers).
final class RichContentVerdictResolverTests: XCTestCase {
    private var rootDirectory: URL!
    private var messagesDirectory: URL!
    private var handler: HTMLContentHandler!
    private var didCloseAccountWork = false

    override func setUp() {
        super.setUp()
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RichContentVerdictResolverTests-\(UUID().uuidString)", isDirectory: true)
        messagesDirectory = rootDirectory.appendingPathComponent("Messages", isDirectory: true)
        handler = HTMLContentHandler(messagesDirectory: messagesDirectory)
    }

    override func tearDown() {
        // The boundary is keyed by directory in a process-wide registry and outlives the
        // handler, so leave it open as it was found.
        if didCloseAccountWork {
            try? handler.reopenAccountWork()
        }
        try? FileManager.default.removeItem(at: rootDirectory)
        handler = nil
        messagesDirectory = nil
        rootDirectory = nil
        super.tearDown()
    }

    // MARK: - Own rows

    /// Own rows are never rich, and that is settled before anything is read: with the
    /// account boundary closed, a received row over the same stored state is undetermined.
    ///
    /// Revert-check: the leading `guard !inputs.isFromMe` in
    /// `RichContentVerdictResolver.verdict` (without it the closed boundary answers
    /// `.unknown`), and the same guard in `cheapTerms` (without it the fallback text and
    /// storage URI answer `.decided(true)`).
    func testVerdict_ownRowWhileAccountWorkClosed_isNotRichWithoutReading() throws {
        let messageID = makeMessageID()
        XCTAssertNotNil(handler.saveHTML(RichContentVerdictResolverFixture.richHTML, for: messageID))
        let bodyURL = try writeBodyFile(Data(RichContentVerdictResolverFixture.richHTML.utf8))
        let own = makeInputs(
            messageID: messageID,
            isFromMe: true,
            bodyStorageURI: bodyURL.absoluteString,
            bodyText: RichContentVerdictResolverFixture.fallbackText,
            snippet: RichContentVerdictResolverFixture.fallbackText
        )
        let received = makeInputs(
            messageID: messageID,
            isFromMe: false,
            bodyStorageURI: bodyURL.absoluteString,
            bodyText: RichContentVerdictResolverFixture.fallbackText,
            snippet: RichContentVerdictResolverFixture.fallbackText
        )
        XCTAssertEqual(cheapTerms(for: own), .decided(false))

        closeAccountWork()
        var classifiedCandidates: [String] = []
        let ownVerdict = RichContentVerdictResolver.verdict(
            for: own,
            handler: handler,
            classify: { html in
                classifiedCandidates.append(html)
                return true
            }
        )

        XCTAssertEqual(ownVerdict, .notRich)
        XCTAssertTrue(classifiedCandidates.isEmpty)
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: received, handler: handler), .unknown)
    }

    // MARK: - Fallback-text term

    /// A row whose plain text is a newsletter's "view in browser / unsubscribe" stub is rich
    /// when it has an HTML source, and a storage URI counts as one even when it dangles: the
    /// card's own pipeline recovers the HTML.
    ///
    /// Revert-check: the `inputs.bodyStorageURI != nil` term of `hasHTMLSource` in
    /// `RichContentVerdictResolver.cheapTerms`. Requiring the file to load leaves this row to
    /// the classifier, which has no candidate.
    func testVerdict_fallbackBodyTextWithStorageURI_isRichWithoutClassifying() {
        let inputs = makeInputs(
            messageID: makeMessageID(),
            bodyStorageURI: danglingBodyStorageURI(),
            bodyText: RichContentVerdictResolverFixture.fallbackText
        )

        XCTAssertEqual(cheapTerms(for: inputs), .decided(true))
        let verdict = RichContentVerdictResolver.verdict(
            for: inputs,
            handler: handler,
            classify: { _ in
                XCTFail("The fallback-text term decides before any HTML is classified")
                return false
            }
        )
        XCTAssertEqual(verdict, .rich)
    }

    /// The message's own file is an HTML source too. The file here is not rich, so only the
    /// fallback-text term can produce this verdict.
    ///
    /// Revert-check: the `handler.htmlFileExists(for:expectedGeneration:)` term of
    /// `hasHTMLSource` in `RichContentVerdictResolver.cheapTerms`.
    func testVerdict_fallbackBodyTextWithOwnFileAndNoStorageURI_isRich() {
        let messageID = makeMessageID()
        XCTAssertNotNil(handler.saveHTML(RichContentVerdictResolverFixture.plainHTML, for: messageID))
        let inputs = makeInputs(
            messageID: messageID,
            bodyText: RichContentVerdictResolverFixture.fallbackText
        )

        XCTAssertEqual(cheapTerms(for: inputs), .decided(true))
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .rich)
    }

    /// Fallback text alone decides nothing: with no HTML source there would be no card to
    /// show, so the classifier decides, and plain text is no candidate.
    ///
    /// Revert-check: the `hasHTMLSource` requirement in `RichContentVerdictResolver.cheapTerms`
    /// (returning `.decided(true)` on fallback text alone).
    func testVerdict_fallbackBodyTextWithoutHTMLSource_isLeftToClassifierAndNotRich() {
        let inputs = makeInputs(
            messageID: makeMessageID(),
            bodyText: RichContentVerdictResolverFixture.fallbackText
        )

        XCTAssertEqual(cheapTerms(for: inputs), .classifierDecides)
        XCTAssertEqual(candidate(for: inputs), RichContentVerdictResolver.ClassifierCandidate.none)
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .notRich)
    }

    /// The snippet stands in for a body the row never stored.
    ///
    /// Revert-check: the `?? inputs.snippet` in `RichContentVerdictResolver.cheapTerms`.
    func testVerdict_nilBodyTextWithFallbackSnippetAndStorageURI_isRich() {
        let inputs = makeInputs(
            messageID: makeMessageID(),
            bodyStorageURI: danglingBodyStorageURI(),
            bodyText: nil,
            snippet: RichContentVerdictResolverFixture.fallbackText
        )

        XCTAssertEqual(cheapTerms(for: inputs), .decided(true))
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .rich)
    }

    /// A blank body still suppresses the snippet: the operator is nil-coalescing, not
    /// "first non-empty", and every writer and the loader must agree on that or a stored
    /// verdict and the load disagree for these rows.
    ///
    /// Revert-check: `inputs.bodyText ?? inputs.snippet` in
    /// `RichContentVerdictResolver.cheapTerms`. Choosing the first non-empty of the two
    /// answers `.decided(true)` here.
    func testVerdict_blankBodyTextWithFallbackSnippetAndStorageURI_isNotRich() {
        for blankBodyText in ["", "  \n"] {
            let inputs = makeInputs(
                messageID: makeMessageID(),
                bodyStorageURI: danglingBodyStorageURI(),
                bodyText: blankBodyText,
                snippet: RichContentVerdictResolverFixture.fallbackText
            )

            XCTAssertEqual(cheapTerms(for: inputs), .classifierDecides)
            XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .notRich)
        }
    }

    // MARK: - Candidate order

    /// Revert-check: the own-file branch coming first in
    /// `RichContentVerdictResolver.classifierCandidate`.
    func testClassifierCandidate_ownFile_winsOverStorageURIFileAndBodyText() throws {
        let messageID = makeMessageID()
        let ownHTML = "<html><body><p>OWN_FILE_TOKEN</p></body></html>"
        XCTAssertNotNil(handler.saveHTML(ownHTML, for: messageID))
        let bodyURL = try writeBodyFile(Data("<html><body><p>URI_FILE_TOKEN</p></body></html>".utf8))
        let inputs = makeInputs(
            messageID: messageID,
            bodyStorageURI: bodyURL.absoluteString,
            bodyText: "<p>BODY_TEXT_TOKEN</p>"
        )

        XCTAssertEqual(candidate(for: inputs), .html(ownHTML))
    }

    /// Any file that exists and loads wins, whatever it holds. The control row has the same
    /// rich storage-URI file and body, and no own file.
    ///
    /// Revert-check: `classifierCandidate` returning `.html(html)` for every own file that
    /// loads. Skipping an empty one falls through to the storage-URI file and answers
    /// `.rich`.
    func testVerdict_emptyOwnFile_isNotRichWithoutFallingThrough() throws {
        let messageID = makeMessageID()
        XCTAssertNotNil(handler.saveHTML("", for: messageID))
        let bodyURL = try writeBodyFile(Data(RichContentVerdictResolverFixture.richHTML.utf8))
        let inputs = makeInputs(
            messageID: messageID,
            bodyStorageURI: bodyURL.absoluteString,
            bodyText: RichContentVerdictResolverFixture.richHTML
        )
        let controlWithoutOwnFile = makeInputs(
            messageID: makeMessageID(),
            bodyStorageURI: bodyURL.absoluteString,
            bodyText: RichContentVerdictResolverFixture.richHTML
        )

        XCTAssertEqual(candidate(for: inputs), .html(""))
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .notRich)
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: controlWithoutOwnFile, handler: handler), .rich)
    }

    /// Both spellings a stored URI takes: a `file://` URL and an absolute path.
    ///
    /// Revert-check: the `bodyStorageURI` branch of
    /// `RichContentVerdictResolver.classifierCandidate`. Without it the body text is the
    /// candidate.
    func testClassifierCandidate_noOwnFile_usesStorageURIFileOverBodyText() throws {
        let uriHTML = "<html><body><p>URI_FILE_TOKEN</p></body></html>"
        let bodyURL = try writeBodyFile(Data(uriHTML.utf8))

        for bodyStorageURI in [bodyURL.absoluteString, bodyURL.path] {
            let inputs = makeInputs(
                messageID: makeMessageID(),
                bodyStorageURI: bodyStorageURI,
                bodyText: "<p>BODY_TEXT_TOKEN</p>"
            )

            XCTAssertEqual(candidate(for: inputs), .html(uriHTML), bodyStorageURI)
        }
    }

    /// A raw RFC 822 blob in `bodyText` is classified by its HTML part, not as a whole.
    ///
    /// Revert-check: the `RawEmailSourceSanitizer.extractHTMLText` step of
    /// `RichContentVerdictResolver.classifierCandidate`. Without it the whole blob (headers
    /// and plain part included) is the candidate.
    func testClassifierCandidate_rawSourceBodyText_usesEmbeddedHTMLPart() throws {
        let rawSource = RichContentVerdictResolverFixture.rawSourceWithRichHTMLPart
        let embeddedHTML = try XCTUnwrap(RawEmailSourceSanitizer.extractHTMLText(from: rawSource))
        XCTAssertTrue(embeddedHTML.contains("<section>"))
        XCTAssertFalse(embeddedHTML.contains("Delivered-To:"))
        let inputs = makeInputs(messageID: makeMessageID(), bodyText: rawSource)

        XCTAssertEqual(candidate(for: inputs), .html(embeddedHTML))
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .rich)
    }

    /// The last candidate, and a storage URI whose file is gone is no candidate at all: it
    /// falls through rather than making the row undetermined.
    ///
    /// Revert-check: the `ChatBubbleTextProcessor.containsHTMLTags(bodyText)` candidate at
    /// the end of `RichContentVerdictResolver.classifierCandidate`.
    func testClassifierCandidate_bodyTextWithHTMLTags_isClassifiedAsIs() {
        let richBody = makeInputs(
            messageID: makeMessageID(),
            bodyStorageURI: danglingBodyStorageURI(),
            bodyText: RichContentVerdictResolverFixture.richHTML
        )
        let plainBody = makeInputs(
            messageID: makeMessageID(),
            bodyText: RichContentVerdictResolverFixture.plainHTML
        )

        XCTAssertEqual(candidate(for: richBody), .html(RichContentVerdictResolverFixture.richHTML))
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: richBody, handler: handler), .rich)
        XCTAssertEqual(candidate(for: plainBody), .html(RichContentVerdictResolverFixture.plainHTML))
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: plainBody, handler: handler), .notRich)
    }

    /// No file, no URI, and a body that is absent or plain text: the classifier term is
    /// false without the classifier running.
    ///
    /// Revert-check: the `.none` candidate in `RichContentVerdictResolver.classifierCandidate`
    /// and its `isRich = false` in `verdict`. Handing plain text to the classifier calls the
    /// closure, which answers rich.
    func testVerdict_noHTMLCandidate_isNotRichWithoutClassifying() {
        let bodyTexts: [String?] = [nil, "See you at noon."]
        for bodyText in bodyTexts {
            let inputs = makeInputs(messageID: makeMessageID(), bodyText: bodyText, snippet: "See you at noon.")

            XCTAssertEqual(candidate(for: inputs), RichContentVerdictResolver.ClassifierCandidate.none)
            let verdict = RichContentVerdictResolver.verdict(
                for: inputs,
                handler: handler,
                classify: { _ in
                    XCTFail("A row with no HTML candidate must not reach the classifier")
                    return true
                }
            )
            XCTAssertEqual(verdict, .notRich)
        }
    }

    // MARK: - Just-saved HTML

    /// Sync classifies the string it has just written rather than reading the file back. The
    /// file on disk here holds something else and the boundary is closed, so any read
    /// through the handler would change the answer.
    ///
    /// Revert-check: the `.justSaved` case in `RichContentVerdictResolver.classifierCandidate`
    /// (reading the file instead classifies the plain document) and in `verdict` (capturing a
    /// generation for it answers `.unknown` once the boundary is closed).
    func testVerdict_justSavedHTML_classifiesInHandStringWithoutReadingHandler() {
        let messageID = makeMessageID()
        XCTAssertNotNil(handler.saveHTML(RichContentVerdictResolverFixture.plainHTML, for: messageID))
        let inputs = makeInputs(messageID: messageID)
        XCTAssertEqual(
            candidate(for: inputs, storedHTML: .justSaved(RichContentVerdictResolverFixture.richHTML)),
            .html(RichContentVerdictResolverFixture.richHTML)
        )

        closeAccountWork()
        var classifiedCandidates: [String] = []
        let richVerdict = RichContentVerdictResolver.verdict(
            for: inputs,
            storedHTML: .justSaved(RichContentVerdictResolverFixture.richHTML),
            handler: handler,
            classify: { html in
                classifiedCandidates.append(html)
                return RichContentClassifier.hasGenuineRichContentAfterCleanup(html)
            }
        )
        let plainVerdict = RichContentVerdictResolver.verdict(
            for: inputs,
            storedHTML: .justSaved(RichContentVerdictResolverFixture.plainHTML),
            handler: handler
        )

        XCTAssertEqual(richVerdict, .rich)
        XCTAssertEqual(classifiedCandidates, [RichContentVerdictResolverFixture.richHTML])
        XCTAssertEqual(plainVerdict, .notRich)
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .unknown)
    }

    /// A row whose HTML was just saved has an HTML source by definition, before its
    /// `bodyStorageURI` or file is visible to a read. The control reads the same row through
    /// the handler, where nothing is stored.
    ///
    /// Revert-check: `case .justSaved: hasHTMLSource = true` in
    /// `RichContentVerdictResolver.cheapTerms`.
    func testVerdict_fallbackTextWithJustSavedHTML_isRichWithoutURIOrFile() {
        let inputs = makeInputs(
            messageID: makeMessageID(),
            bodyStorageURI: nil,
            bodyText: RichContentVerdictResolverFixture.fallbackText
        )
        let justSaved = RichContentVerdictResolver.StoredHTML.justSaved(RichContentVerdictResolverFixture.plainHTML)

        XCTAssertEqual(cheapTerms(for: inputs, storedHTML: justSaved), .decided(true))
        let verdict = RichContentVerdictResolver.verdict(
            for: inputs,
            storedHTML: justSaved,
            handler: handler,
            classify: { _ in
                XCTFail("The fallback-text term decides before any HTML is classified")
                return false
            }
        )
        XCTAssertEqual(verdict, .rich)
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .notRich)
    }

    // MARK: - Classifier substitution

    /// Sync substitutes the answer it pre-computed for the exact string it saved. Both
    /// substitutes here answer the opposite of the real classifier.
    ///
    /// Revert-check: `isRich = classify(html)` in `RichContentVerdictResolver.verdict`.
    /// Calling `RichContentClassifier` directly ignores the substitute.
    func testVerdict_classifyClosure_receivesExactCandidateAndItsAnswerIsTheVerdict() {
        let plainInputs = makeInputs(messageID: makeMessageID())
        let richInputs = makeInputs(messageID: makeMessageID())
        XCTAssertNotNil(handler.saveHTML(RichContentVerdictResolverFixture.plainHTML, for: plainInputs.messageID))
        XCTAssertNotNil(handler.saveHTML(RichContentVerdictResolverFixture.richHTML, for: richInputs.messageID))
        var classifiedCandidates: [String] = []

        let substitutedRich = RichContentVerdictResolver.verdict(
            for: plainInputs,
            handler: handler,
            classify: { html in
                classifiedCandidates.append(html)
                return true
            }
        )
        let substitutedNotRich = RichContentVerdictResolver.verdict(
            for: richInputs,
            handler: handler,
            classify: { html in
                classifiedCandidates.append(html)
                return false
            }
        )

        XCTAssertEqual(substitutedRich, .rich)
        XCTAssertEqual(substitutedNotRich, .notRich)
        XCTAssertEqual(
            classifiedCandidates,
            [RichContentVerdictResolverFixture.plainHTML, RichContentVerdictResolverFixture.richHTML]
        )
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: plainInputs, handler: handler), .notRich)
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: richInputs, handler: handler), .rich)
    }

    // MARK: - Undetermined

    /// While the boundary is closed every handler read answers "absent", which says nothing
    /// about the row. A persisted "not rich" from it would render a rich row's text at mount
    /// and swap it for a card on every open.
    ///
    /// Revert-check: the generation capture at the top of `RichContentVerdictResolver.verdict`
    /// returning `.unknown` when `handler.captureAccountGeneration()` is nil. Evaluating
    /// anyway finds no file and answers `.notRich`.
    func testVerdict_closedAccountBoundary_isUnknown() {
        let messageID = makeMessageID()
        XCTAssertNotNil(handler.saveHTML(RichContentVerdictResolverFixture.richHTML, for: messageID))
        let inputs = makeInputs(messageID: messageID)
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .rich)

        closeAccountWork()

        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .unknown)
    }

    /// A generation captured for the previous account reads nothing after the reopen, though
    /// the new account's file is on disk under the same message ID. The second row is decided
    /// by the fallback-text term with no read at all, and is still not a verdict for a
    /// retired generation.
    ///
    /// Revert-check: the trailing `handler.isAccountGenerationCurrent(generation)` re-check in
    /// `RichContentVerdictResolver.verdict`. Without it the stale reads answer "absent" and
    /// the first row is `.notRich`, and the second is `.rich`.
    func testVerdict_staleExpectedAccountGeneration_isUnknown() throws {
        let messageID = makeMessageID()
        let inputs = makeInputs(messageID: messageID)
        let decidedWithoutReading = makeInputs(
            messageID: makeMessageID(),
            bodyStorageURI: danglingBodyStorageURI(),
            bodyText: RichContentVerdictResolverFixture.fallbackText
        )
        let staleGeneration = try XCTUnwrap(handler.captureAccountGeneration())
        closeAccountWork()
        try handler.reopenAccountWork()
        XCTAssertNotNil(handler.saveHTML(RichContentVerdictResolverFixture.richHTML, for: messageID))
        let currentGeneration = try XCTUnwrap(handler.captureAccountGeneration())

        for row in [inputs, decidedWithoutReading] {
            XCTAssertEqual(
                RichContentVerdictResolver.verdict(
                    for: row,
                    handler: handler,
                    expectedAccountGeneration: staleGeneration
                ),
                .unknown
            )
            XCTAssertEqual(
                RichContentVerdictResolver.verdict(
                    for: row,
                    handler: handler,
                    expectedAccountGeneration: currentGeneration
                ),
                .rich
            )
        }
    }

    /// The boundary is cycled after the file was read and while it is being classified, so
    /// only the re-check after the evaluation can notice.
    ///
    /// Revert-check: the trailing `handler.isAccountGenerationCurrent(generation)` re-check in
    /// `RichContentVerdictResolver.verdict`. Without it the previous account's HTML stamps
    /// `.rich`.
    func testVerdict_accountBoundaryCycledDuringClassification_isUnknown() {
        let messageID = makeMessageID()
        XCTAssertNotNil(handler.saveHTML(RichContentVerdictResolverFixture.richHTML, for: messageID))
        let cycledHandler: HTMLContentHandler = handler
        var classificationCount = 0

        let verdict = RichContentVerdictResolver.verdict(
            for: makeInputs(messageID: messageID),
            handler: cycledHandler,
            classify: { _ in
                classificationCount += 1
                cycledHandler.closeAccountWork()
                try? cycledHandler.reopenAccountWork()
                return true
            }
        )

        XCTAssertEqual(classificationCount, 1)
        XCTAssertEqual(verdict, .unknown)
    }

    /// A file that exists but cannot be read is not "no HTML". The first row has nothing
    /// else to classify (a fall-through would answer `.notRich`), the second a rich body (a
    /// fall-through would classify the wrong candidate).
    ///
    /// Revert-check: the own-file branch of `RichContentVerdictResolver.classifierCandidate`
    /// answering `.undetermined` when `handler.loadHTML(for:expectedGeneration:)` is nil, and
    /// `.undetermined` returning `.unknown` in `verdict`.
    ///
    /// HONEST SCOPE: undecodable bytes are the one unreadable-file state a test can produce
    /// on demand. A protected-data or permission failure is not reproduced here; it reaches
    /// the resolver the same way, as a nil from `loadHTML` for a file that exists.
    func testVerdict_ownFileThatCannotBeRead_isUnknownNotNotRich() throws {
        let bodyTexts: [String?] = [nil, RichContentVerdictResolverFixture.richHTML]
        for bodyText in bodyTexts {
            let messageID = makeMessageID()
            try RichContentVerdictResolverFixture.invalidUTF8.write(
                to: messagesDirectory.appendingPathComponent("\(messageID).html")
            )
            let inputs = makeInputs(messageID: messageID, bodyText: bodyText)
            // The premise: present on disk, unreadable as UTF-8.
            XCTAssertTrue(handler.htmlFileExists(for: messageID))
            XCTAssertNil(handler.loadHTML(for: messageID))

            XCTAssertEqual(candidate(for: inputs), .undetermined)
            let verdict = RichContentVerdictResolver.verdict(
                for: inputs,
                handler: handler,
                classify: { _ in
                    XCTFail("An unreadable file leaves nothing to classify")
                    return true
                }
            )
            XCTAssertEqual(verdict, .unknown)
        }
    }

    /// The same for the file at `bodyStorageURI`.
    ///
    /// Revert-check: the `bodyStorageURI` branch of
    /// `RichContentVerdictResolver.classifierCandidate` answering `.undetermined` when
    /// `handler.loadHTML(from:expectedGeneration:)` is nil. Falling through classifies the
    /// rich body text and answers `.rich`.
    func testVerdict_storageURIFileThatCannotBeRead_isUnknownNotNotRich() throws {
        let bodyURL = try writeBodyFile(RichContentVerdictResolverFixture.invalidUTF8)
        let inputs = makeInputs(
            messageID: makeMessageID(),
            bodyStorageURI: bodyURL.absoluteString,
            bodyText: RichContentVerdictResolverFixture.richHTML
        )
        XCTAssertNil(handler.loadHTML(from: bodyURL))

        XCTAssertEqual(candidate(for: inputs), .undetermined)
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .unknown)
    }

    /// A file removed behind the handler's back (not through `deleteHTML`) leaves a present
    /// signature cached, and `htmlFileExists` answers from that cache. One failed load must
    /// clear it. Otherwise the row reads as "exists but unreadable" for as long as the cache
    /// lives, and the resolver never falls through to the body text the way it does for a
    /// row with no file.
    ///
    /// Revert-check: `invalidateStalePresentSignature(for:)` in
    /// `HTMLContentHandler.loadHTMLWithoutBoundary`. Without it the second evaluation below
    /// is still `.undetermined`.
    func testVerdict_ownFileRemovedBehindTheHandler_fallsThroughAfterOneFailedLoad() throws {
        let messageID = makeMessageID()
        let fileURL = messagesDirectory.appendingPathComponent("\(messageID).html")
        // Written and removed directly: the handler's content cache never holds the file,
        // and neither of its caches hears of the removal.
        try Data(RichContentVerdictResolverFixture.plainHTML.utf8).write(to: fileURL)
        XCTAssertTrue(handler.htmlFileExists(for: messageID), "premise: the present signature is cached")
        try FileManager.default.removeItem(at: fileURL)
        XCTAssertTrue(
            handler.htmlFileExists(for: messageID),
            "premise: the cached signature still reports the removed file"
        )

        let inputs = makeInputs(messageID: messageID, bodyText: RichContentVerdictResolverFixture.richHTML)
        XCTAssertEqual(
            candidate(for: inputs),
            .undetermined,
            "The first evaluation still trusts the stale signature and cannot read the file"
        )

        XCTAssertFalse(handler.htmlFileExists(for: messageID), "The failed load dropped the stale signature")
        guard case .html = candidate(for: inputs) else {
            return XCTFail("With no file reported, the resolver falls through to the body text")
        }
        XCTAssertEqual(RichContentVerdictResolver.verdict(for: inputs, handler: handler), .rich)
    }

    // MARK: - Helpers

    private func makeMessageID() -> String {
        "verdict-resolver-\(UUID().uuidString)"
    }

    private func makeInputs(
        messageID: String,
        isFromMe: Bool = false,
        bodyStorageURI: String? = nil,
        bodyText: String? = nil,
        snippet: String? = nil
    ) -> RichContentVerdictInputs {
        RichContentVerdictInputs(
            messageID: messageID,
            isFromMe: isFromMe,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            snippet: snippet
        )
    }

    /// Writes a file outside the Messages directory, as a `bodyStorageURI` target.
    private func writeBodyFile(_ contents: Data) throws -> URL {
        let directory = rootDirectory.appendingPathComponent("Bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).html")
        try contents.write(to: url)
        return url
    }

    /// A storage URI naming a file that does not exist.
    private func danglingBodyStorageURI() -> String {
        rootDirectory
            .appendingPathComponent("Bodies", isDirectory: true)
            .appendingPathComponent("missing-\(UUID().uuidString).html")
            .absoluteString
    }

    private func closeAccountWork() {
        handler.closeAccountWork()
        didCloseAccountWork = true
    }

    private func cheapTerms(
        for inputs: RichContentVerdictInputs,
        storedHTML: RichContentVerdictResolver.StoredHTML = .readThroughHandler
    ) -> RichContentVerdictResolver.CheapTerms {
        RichContentVerdictResolver.cheapTerms(
            for: inputs,
            storedHTML: storedHTML,
            handler: handler,
            generation: nil
        )
    }

    private func candidate(
        for inputs: RichContentVerdictInputs,
        storedHTML: RichContentVerdictResolver.StoredHTML = .readThroughHandler
    ) -> RichContentVerdictResolver.ClassifierCandidate {
        RichContentVerdictResolver.classifierCandidate(
            for: inputs,
            storedHTML: storedHTML,
            handler: handler,
            generation: nil
        )
    }
}

private enum RichContentVerdictResolverFixture {
    /// `RichContentClassifier` answers rich for any `<section>`.
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

    static let plainHTML = "<html><body><p>See you at noon.</p></body></html>"

    /// What `NewsletterFallbackText.looksLikeFallbackText` recognizes: a newsletter marker
    /// and at least two lines carrying a URL.
    static let fallbackText = """
    Example Museum
    https://example.com/view

    Unsubscribe
    https://example.com/unsubscribe
    """

    /// Bytes that are not UTF-8, so a file holding them exists but cannot be loaded.
    static let invalidUTF8 = Data([0xC3, 0x28, 0xA0, 0xA1])

    /// A raw message `RawEmailSourceSanitizer` accepts (transport headers plus a multipart
    /// boundary) whose HTML part is `richHTML`. The plain part has no colon on any line, so
    /// none of it reads as a part header.
    static let rawSourceWithRichHTMLPart = """
    Delivered-To: person@example.com
    Received: by 2002:a05:6e04:71a:b0:3ac:63b9:5e27 with SMTP id o26csp2106356imz;
    X-Received: by 2002:ac8:7dd4:0:b0:503:4257:da03 with SMTP id d75a77;
    Return-Path: <statements@example.com>
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="statement-boundary-123"

    --statement-boundary-123
    Content-Type: text/plain; charset="utf-8"
    Content-Transfer-Encoding: 8bit

    Statement ready
    Your monthly account statement is now available.

    --statement-boundary-123
    Content-Type: text/html; charset="utf-8"
    Content-Transfer-Encoding: 8bit

    \(richHTML)

    --statement-boundary-123--
    """
}
