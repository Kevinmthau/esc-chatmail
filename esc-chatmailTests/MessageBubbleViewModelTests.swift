import XCTest
@testable import esc_chatmail

@MainActor
final class MessageBubbleViewModelTests: XCTestCase {
    func testLoadIfNeeded_appliesSenderAndContentState() async {
        let expectedLink = SharedDocumentLink(
            id: "google-doc",
            url: URL(string: "https://docs.google.com/document/d/abc123/edit")!,
            kind: .googleDoc
        )
        let loader = MockMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(
                    name: "Alice Example",
                    avatarURL: "file:///avatar",
                    imageData: Data([0x01, 0x02])
                )
            ],
            contentResults: [
                MessageBubbleContentResult(
                    fullTextContent: "Project update",
                    hasRichHTMLContent: true,
                    sharedDocumentLinks: [expectedLink],
                    forwardedDisplayContent: nil,
                    htmlAnalysis: .placeholder(hasHTMLSource: true)
                )
            ]
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(using: makeContext())

        XCTAssertEqual(viewModel.senderName, "Alice Example")
        XCTAssertEqual(viewModel.senderAvatarURL, "file:///avatar")
        XCTAssertEqual(viewModel.senderImageData, Data([0x01, 0x02]))
        XCTAssertEqual(viewModel.fullTextContent, "Project update")
        XCTAssertTrue(viewModel.hasRichHTMLContent)
        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.sharedDocumentLinks, [expectedLink])
        XCTAssertNil(viewModel.forwardedDisplayContent)
        XCTAssertTrue(viewModel.htmlAnalysis.hasHTMLSource)
    }

    func testLoadIfNeeded_skipsReloadForSameSignature() async {
        let loader = MockMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(name: "Alice Example", avatarURL: nil, imageData: nil)
            ],
            contentResults: [
                MessageBubbleContentResult(
                    fullTextContent: "First load",
                    hasRichHTMLContent: false,
                    sharedDocumentLinks: [],
                    forwardedDisplayContent: nil,
                    htmlAnalysis: .empty
                )
            ]
        )
        let viewModel = MessageBubbleViewModel(loader: loader)
        let context = makeContext()

        await viewModel.loadIfNeeded(using: context)
        await viewModel.loadIfNeeded(using: context)

        let senderCallCount = await loader.senderCallCount()
        let contentCallCount = await loader.contentCallCount()
        XCTAssertEqual(senderCallCount, 1)
        XCTAssertEqual(contentCallCount, 1)
        XCTAssertEqual(viewModel.fullTextContent, "First load")
    }

    func testLoadIfNeeded_reloadsForNewSignature() async {
        let loader = MockMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(name: "Alice Example", avatarURL: nil, imageData: nil),
                MessageBubbleSenderResult(name: "Bob Example", avatarURL: nil, imageData: nil)
            ],
            contentResults: [
                MessageBubbleContentResult(
                    fullTextContent: "First load",
                    hasRichHTMLContent: false,
                    sharedDocumentLinks: [],
                    forwardedDisplayContent: nil,
                    htmlAnalysis: .empty
                ),
                MessageBubbleContentResult(
                    fullTextContent: "Second load",
                    hasRichHTMLContent: true,
                    sharedDocumentLinks: [],
                    forwardedDisplayContent: nil,
                    htmlAnalysis: .placeholder(hasHTMLSource: true)
                )
            ]
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(using: makeContext())
        await viewModel.loadIfNeeded(using: makeContext(messageID: "msg-2", signature: "sig-2", senderEmail: "bob@example.com"))

        let senderCallCount = await loader.senderCallCount()
        let contentCallCount = await loader.contentCallCount()
        XCTAssertEqual(senderCallCount, 2)
        XCTAssertEqual(contentCallCount, 2)
        XCTAssertEqual(viewModel.senderName, "Bob Example")
        XCTAssertEqual(viewModel.fullTextContent, "Second load")
        XCTAssertTrue(viewModel.hasRichHTMLContent)
    }

    func testLoadIfNeeded_reloadsSameMessageWhenSignatureChanges() async {
        let loader = MockMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(name: "Old Contact Name", avatarURL: nil, imageData: nil),
                MessageBubbleSenderResult(name: "Updated Contact Name", avatarURL: nil, imageData: nil)
            ],
            contentResults: [
                MessageBubbleContentResult(
                    fullTextContent: "Same body",
                    hasRichHTMLContent: false,
                    sharedDocumentLinks: [],
                    forwardedDisplayContent: nil,
                    htmlAnalysis: .empty
                ),
                MessageBubbleContentResult(
                    fullTextContent: "Same body",
                    hasRichHTMLContent: false,
                    sharedDocumentLinks: [],
                    forwardedDisplayContent: nil,
                    htmlAnalysis: .empty
                )
            ]
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(using: makeContext(signature: "sig-1|contacts:0"))
        await viewModel.loadIfNeeded(using: makeContext(signature: "sig-1|contacts:1"))

        let senderCallCount = await loader.senderCallCount()
        let contentCallCount = await loader.contentCallCount()
        XCTAssertEqual(senderCallCount, 2)
        XCTAssertEqual(contentCallCount, 2)
        XCTAssertEqual(viewModel.senderName, "Updated Contact Name")
    }

    private func makeContext(
        messageID: String = "msg-1",
        signature: String = "sig-1",
        senderEmail: String = "alice@example.com"
    ) -> MessageBubbleLoadContext {
        MessageBubbleLoadContext(
            messageID: messageID,
            contentSignature: signature,
            prefetchedSenderName: "Prefetched Name",
            senderRequest: MessageBubbleSenderRequest(
                email: senderEmail,
                personDisplayName: nil,
                personAvatarURL: "file:///person-avatar"
            ),
            contentRequest: MessageBubbleContentRequest(
                messageID: messageID,
                bodyText: "Body",
                bodyStorageURI: nil,
                cleanedSnippet: "Cleaned snippet",
                snippet: "Snippet",
                subject: "Subject",
                senderName: "Alice Example",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                isForwardedEmail: false,
                isLikelyCalendarInvite: false,
                effectiveSenderEmail: senderEmail,
                attachmentSnapshots: []
            )
        )
    }
}

actor MockMessageBubbleLoader: MessageBubbleLoading {
    private var senderResults: [MessageBubbleSenderResult]
    private var contentResults: [MessageBubbleContentResult]
    private var senderCalls = 0
    private var contentCalls = 0

    init(
        senderResults: [MessageBubbleSenderResult],
        contentResults: [MessageBubbleContentResult]
    ) {
        self.senderResults = senderResults
        self.contentResults = contentResults
    }

    func loadSenderInfo(from request: MessageBubbleSenderRequest) async -> MessageBubbleSenderResult {
        senderCalls += 1
        if !senderResults.isEmpty {
            return senderResults.removeFirst()
        }
        return MessageBubbleSenderResult(
            name: PersonDisplayNameResolver.fallbackSenderName(),
            avatarURL: request.personAvatarURL,
            imageData: nil
        )
    }

    func loadContent(from request: MessageBubbleContentRequest) async -> MessageBubbleContentResult {
        contentCalls += 1
        if !contentResults.isEmpty {
            return contentResults.removeFirst()
        }
        return MessageBubbleContentResult(
            fullTextContent: request.bodyText,
            hasRichHTMLContent: false,
            sharedDocumentLinks: [],
            forwardedDisplayContent: nil,
            htmlAnalysis: .placeholder(hasHTMLSource: request.hasHTMLSource)
        )
    }

    func senderCallCount() -> Int {
        senderCalls
    }

    func contentCallCount() -> Int {
        contentCalls
    }
}

final class MessageBubbleRenderingHelpersTests: XCTestCase {
    func testContentSignature_changesWhenBodyDiffersAfter64Characters() {
        let sharedPrefix = String(repeating: "a", count: 64)

        let firstSignature = MessageBubble.contentSignature(
            bodyStorageURI: nil,
            bodyText: sharedPrefix + " tail-one",
            snippet: "Snippet",
            hasHTMLSource: false,
            htmlSourceSignature: "missing",
            contactRefreshToken: 0
        )
        let secondSignature = MessageBubble.contentSignature(
            bodyStorageURI: nil,
            bodyText: sharedPrefix + " tail-two",
            snippet: "Snippet",
            hasHTMLSource: false,
            htmlSourceSignature: "missing",
            contactRefreshToken: 0
        )

        XCTAssertNotEqual(firstSignature, secondSignature)
    }

    func testContentSignature_changesWhenChatPreviewTextChanges() {
        let firstSignature = MessageBubble.contentSignature(
            bodyStorageURI: nil,
            bodyText: "Body",
            chatPreviewText: "First chat preview",
            snippet: "Snippet",
            hasHTMLSource: false,
            htmlSourceSignature: "missing",
            contactRefreshToken: 0
        )
        let secondSignature = MessageBubble.contentSignature(
            bodyStorageURI: nil,
            bodyText: "Body",
            chatPreviewText: "Second chat preview",
            snippet: "Snippet",
            hasHTMLSource: false,
            htmlSourceSignature: "missing",
            contactRefreshToken: 0
        )

        XCTAssertNotEqual(firstSignature, secondSignature)
    }

    func testContentSignature_changesWhenCanonicalHTMLFileChangesWithoutBodyStorageURIChange() {
        let messageId = "bubble-signature-\(UUID().uuidString)"
        let handler = HTMLContentHandler.shared
        handler.deleteHTML(for: messageId)
        defer { handler.deleteHTML(for: messageId) }

        let firstSignature = MessageBubble.contentSignature(
            bodyStorageURI: "file:///tmp/stale-fallback.html",
            bodyText: "Body",
            snippet: "Snippet",
            hasHTMLSource: true,
            htmlSourceSignature: handler.htmlSourceSignature(
                messageId: messageId,
                bodyStorageURI: "file:///tmp/stale-fallback.html"
            ),
            contactRefreshToken: 0
        )

        _ = handler.saveHTML("<html><body>Recovered</body></html>", for: messageId)

        let secondSignature = MessageBubble.contentSignature(
            bodyStorageURI: "file:///tmp/stale-fallback.html",
            bodyText: "Body",
            snippet: "Snippet",
            hasHTMLSource: true,
            htmlSourceSignature: handler.htmlSourceSignature(
                messageId: messageId,
                bodyStorageURI: "file:///tmp/stale-fallback.html"
            ),
            contactRefreshToken: 0
        )

        XCTAssertNotEqual(firstSignature, secondSignature)
    }

    func testContentSignature_changesWhenHeaderSenderNameChanges() {
        let firstSignature = MessageBubble.contentSignature(
            bodyStorageURI: nil,
            bodyText: "Body",
            snippet: "Snippet",
            hasHTMLSource: false,
            htmlSourceSignature: "missing",
            contactRefreshToken: 0,
            senderEmail: "john.smith@example.com",
            senderDisplayName: nil,
            senderHeaderDisplayName: nil
        )
        let secondSignature = MessageBubble.contentSignature(
            bodyStorageURI: nil,
            bodyText: "Body",
            snippet: "Snippet",
            hasHTMLSource: false,
            htmlSourceSignature: "missing",
            contactRefreshToken: 0,
            senderEmail: "john.smith@example.com",
            senderDisplayName: nil,
            senderHeaderDisplayName: "John Smith"
        )

        XCTAssertNotEqual(firstSignature, secondSignature)
    }

    func testResolvedProcessedText_fallsBackToProcessedSnippetWhenBodyCleansToNil() {
        let result = MessageContentView.resolvedProcessedText(
            bodyText: """
            On Tue, Jan 2, 2026 at 9:41 AM Alice Example <alice@example.com> wrote:
            > Earlier message
            """,
            snippet: "Tom &amp; Jerry"
        )

        XCTAssertEqual(result, "Tom & Jerry")
    }

    func testResolvedVisibleText_outgoingReplyUsesFullBodyBeforeSnippet() throws {
        let replyBody = """
        Can we please see alts for:

        Primary bedroom drapery
        Kitchen backsplash

        Thank you!

        On Tue, Jan 2, 2026 at 9:41 AM Alice Example <alice@example.com> wrote:
        > Original request that should stay out of the bubble.
        """

        let result = try XCTUnwrap(
            MessageContentView.resolvedVisibleText(
                fullTextContent: nil,
                fallbackPreviewText: "Can we please see alts for:",
                outgoingBodyText: replyBody,
                isOutgoingPlainTextMessage: true
            )
        )

        XCTAssertTrue(result.contains("Can we please see alts for:\n\nPrimary bedroom drapery"))
        XCTAssertTrue(result.contains("Kitchen backsplash"))
        XCTAssertTrue(result.contains("Thank you!"))
        XCTAssertFalse(result.contains("Original request that should stay out of the bubble."))
        XCTAssertNotEqual(result, "Can we please see alts for:")
    }

    func testResolvedVisibleText_outgoingSnippetBodyKeepsLoadedContent() throws {
        let loadedText = """
        Can we please see alts for:

        Primary bedroom drapery
        Kitchen backsplash

        Thank you!
        """

        let result = try XCTUnwrap(
            MessageContentView.resolvedVisibleText(
                fullTextContent: loadedText,
                fallbackPreviewText: "Can we please see alts for:",
                outgoingBodyText: "Can we please see alts for:",
                isOutgoingPlainTextMessage: true
            )
        )

        XCTAssertEqual(result, loadedText)
    }

    func testResolvedVisibleText_prefersChatPreviewBeforeLegacyFallback() throws {
        let result = try XCTUnwrap(
            MessageContentView.resolvedVisibleText(
                fullTextContent: nil,
                fallbackPreviewText: "Legacy compact fallback",
                chatPreviewText: "Canonical chat preview\n\nSecond line",
                outgoingBodyText: nil,
                isOutgoingPlainTextMessage: false
            )
        )

        XCTAssertEqual(result, "Canonical chat preview\n\nSecond line")
    }

    func testResolvedVisibleText_removesSharedDocumentLinksFromChatPreviewText() throws {
        let url = try XCTUnwrap(URL(string: "https://docs.google.com/document/d/abc123/edit"))
        let link = SharedDocumentLink(
            id: SharedDocumentLinkExtractor.dedupeKey(for: url, kind: .googleDoc),
            url: url,
            kind: .googleDoc
        )

        let result = try XCTUnwrap(
            MessageContentView.resolvedVisibleText(
                fullTextContent: nil,
                fallbackPreviewText: nil,
                chatPreviewText: "Here is the doc: https://docs.google.com/document/d/abc123/edit",
                outgoingBodyText: nil,
                isOutgoingPlainTextMessage: false,
                sharedDocumentLinks: [link]
            )
        )

        XCTAssertEqual(result, "Here is the doc:")
    }

    func testResolvedVisibleText_outgoingLongSingleTokenBodyBeatsTruncatedPrefix() throws {
        let fullURL = "https://example.com/shared/document/abcdefghijklmnopqrstuvwxyz"
        let truncatedURL = "https://example.com/shared/document/abc"

        let result = try XCTUnwrap(
            MessageContentView.resolvedVisibleText(
                fullTextContent: truncatedURL,
                fallbackPreviewText: truncatedURL,
                outgoingBodyText: fullURL,
                isOutgoingPlainTextMessage: true
            )
        )

        XCTAssertEqual(result, fullURL)
    }
}

final class OriginalEmailMetadataFormatterTests: XCTestCase {
    func testSenderLineWithEmailOnlyPreservesRawAddress() {
        let senderLine = OriginalEmailMetadataFormatter.senderLine(
            senderName: nil,
            senderEmail: "john.smith@example.com"
        )

        XCTAssertEqual(senderLine, "john.smith@example.com")
    }

    func testSenderLineWithNameAndEmailIncludesBoth() {
        let senderLine = OriginalEmailMetadataFormatter.senderLine(
            senderName: "John Smith",
            senderEmail: "john.smith@example.com"
        )

        XCTAssertEqual(senderLine, "John Smith <john.smith@example.com>")
    }
}
