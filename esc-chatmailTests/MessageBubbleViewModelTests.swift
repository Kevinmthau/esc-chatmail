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
                    sharedDocumentLinks: [expectedLink]
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
                    sharedDocumentLinks: []
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
                    sharedDocumentLinks: []
                ),
                MessageBubbleContentResult(
                    fullTextContent: "Second load",
                    hasRichHTMLContent: true,
                    sharedDocumentLinks: []
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
                snippet: "Snippet",
                hasHTMLSource: false,
                hasAttachments: false,
                isFromMe: false,
                effectiveSenderEmail: senderEmail
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
            name: EmailNormalizer.formatAsDisplayName(email: request.email),
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
            sharedDocumentLinks: []
        )
    }

    func senderCallCount() -> Int {
        senderCalls
    }

    func contentCallCount() -> Int {
        contentCalls
    }
}
