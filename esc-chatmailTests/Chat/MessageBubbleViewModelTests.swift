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

    // MARK: - In-place refresh retention (issue #151, Fix 3)

    /// A signature bump for the message already on screen must not blank the bubble: the previous
    /// content stays published until the reload swaps in atomically. Blanking would collapse a tall
    /// HTML-source bubble to the "Loading..." pill and regrow it, shifting chat scroll position.
    func testLoadIfNeeded_keepsPublishedContentWhileSameMessageRefreshIsInFlight() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(
                    name: "Old Contact Name",
                    avatarURL: "file:///old-avatar",
                    imageData: Data([0x01])
                ),
                MessageBubbleSenderResult(
                    name: "Updated Contact Name",
                    avatarURL: "file:///new-avatar",
                    imageData: Data([0x02])
                )
            ],
            contentResults: [
                Self.makeContentResult(text: "Tall HTML body", inlineContentID: "cid-old"),
                Self.makeContentResult(text: "Refreshed body", inlineContentID: "cid-new")
            ],
            gatedCallIndex: 2
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(using: makeContext(signature: "sig-1|contacts:0", hasHTMLSource: true))
        XCTAssertTrue(viewModel.hasLoadedContent)

        let refresh = Task {
            await viewModel.loadIfNeeded(using: makeContext(signature: "sig-1|contacts:1", hasHTMLSource: true))
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated refresh never started")

        // Mid-refresh: everything the bubble measures its height from is still published.
        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.fullTextContent, "Tall HTML body")
        XCTAssertTrue(viewModel.hasRichHTMLContent)
        XCTAssertEqual(viewModel.htmlAnalysis.referencedInlineContentIDs, ["cid-old"])
        XCTAssertEqual(viewModel.sharedDocumentLinks.map(\.id), ["link-cid-old"])
        XCTAssertEqual(viewModel.forwardedDisplayContent?.subject, "Forwarded cid-old")
        XCTAssertEqual(viewModel.senderName, "Old Contact Name")
        XCTAssertEqual(viewModel.senderAvatarURL, "file:///old-avatar")
        XCTAssertEqual(viewModel.senderImageData, Data([0x01]))

        await loader.release()
        await refresh.value

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.fullTextContent, "Refreshed body")
        XCTAssertEqual(viewModel.htmlAnalysis.referencedInlineContentIDs, ["cid-new"])
        XCTAssertEqual(viewModel.sharedDocumentLinks.map(\.id), ["link-cid-new"])
        XCTAssertEqual(viewModel.forwardedDisplayContent?.subject, "Forwarded cid-new")
        XCTAssertEqual(viewModel.senderName, "Updated Contact Name")
        XCTAssertEqual(viewModel.senderAvatarURL, "file:///new-avatar")
        XCTAssertEqual(viewModel.senderImageData, Data([0x02]))
    }

    /// Retention is scoped to the same message: a recycled bubble bound to a different message
    /// must clear immediately so the previous message's body never renders under the new one.
    func testLoadIfNeeded_clearsPublishedContentWhenMessageIdentityChanges() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(
                    name: "Alice Example",
                    avatarURL: "file:///alice-avatar",
                    imageData: Data([0x01])
                ),
                MessageBubbleSenderResult(name: "Bob Example", avatarURL: nil, imageData: nil)
            ],
            contentResults: [
                Self.makeContentResult(text: "Alice body", inlineContentID: "cid-alice"),
                Self.makeContentResult(text: "Bob body", inlineContentID: "cid-bob")
            ],
            gatedCallIndex: 2
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(using: makeContext(hasHTMLSource: true))

        let reload = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(
                    messageID: "msg-2",
                    signature: "sig-2",
                    senderEmail: "bob@example.com",
                    hasHTMLSource: true
                )
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated reload never started")

        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertNil(viewModel.fullTextContent)
        XCTAssertFalse(viewModel.hasRichHTMLContent)
        XCTAssertTrue(viewModel.htmlAnalysis.referencedInlineContentIDs.isEmpty)
        XCTAssertTrue(viewModel.sharedDocumentLinks.isEmpty)
        XCTAssertNil(viewModel.forwardedDisplayContent)
        XCTAssertEqual(viewModel.senderName, "Prefetched Name")
        XCTAssertNil(viewModel.senderAvatarURL)
        XCTAssertNil(viewModel.senderImageData)

        await loader.release()
        await reload.value

        XCTAssertEqual(viewModel.fullTextContent, "Bob body")
    }

    /// A refresh that is cancelled mid-flight publishes nothing, so the retained content belongs to
    /// the *previous* signature. The next attempt must reload rather than short-circuit on it.
    func testLoadIfNeeded_reloadsAfterCancelledRefreshRatherThanKeepingStaleContent() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(name: "Old Contact Name", avatarURL: nil, imageData: nil),
                MessageBubbleSenderResult(name: "Abandoned Name", avatarURL: nil, imageData: nil),
                MessageBubbleSenderResult(name: "Retried Name", avatarURL: nil, imageData: nil)
            ],
            contentResults: [
                Self.makeContentResult(text: "First body", inlineContentID: "cid-1"),
                Self.makeContentResult(text: "Abandoned body", inlineContentID: "cid-2"),
                Self.makeContentResult(text: "Retried body", inlineContentID: "cid-3")
            ],
            gatedCallIndex: 2
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(using: makeContext(signature: "sig-1|contacts:0", hasHTMLSource: true))

        let refresh = Task {
            await viewModel.loadIfNeeded(using: self.makeContext(signature: "sig-1|contacts:1", hasHTMLSource: true))
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated refresh never started")
        refresh.cancel()
        await loader.release()
        await refresh.value

        // Nothing was published by the cancelled refresh, so the old body is still on screen.
        XCTAssertEqual(viewModel.fullTextContent, "First body")
        XCTAssertEqual(viewModel.senderName, "Old Contact Name")

        await viewModel.loadIfNeeded(using: makeContext(signature: "sig-1|contacts:1", hasHTMLSource: true))

        XCTAssertEqual(viewModel.fullTextContent, "Retried body")
        XCTAssertEqual(viewModel.senderName, "Retried Name")
        let contentCallCount = await loader.contentCallCount()
        XCTAssertEqual(contentCallCount, 3)
    }

    /// Outgoing bubbles take the `senderRequest == nil` branch (`ChatMessageRowModel`
    /// .makeSenderRequest returns nil when `isFromMe`), which is exactly the branch a post-send
    /// refresh runs through — so its retention needs its own coverage.
    func testLoadIfNeeded_keepsOutgoingBubbleContentWhileRefreshIsInFlight() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [],
            contentResults: [
                Self.makeContentResult(text: "Sent body", inlineContentID: "cid-sent"),
                Self.makeContentResult(text: "Refreshed sent body", inlineContentID: "cid-sent-2")
            ],
            gatedCallIndex: 2
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(
            using: makeContext(signature: "sig-1|html:a", hasHTMLSource: true, includesSenderRequest: false)
        )
        XCTAssertTrue(viewModel.hasLoadedContent)

        let refresh = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(signature: "sig-1|html:b", hasHTMLSource: true, includesSenderRequest: false)
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated content load never started")

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.fullTextContent, "Sent body")
        XCTAssertEqual(viewModel.htmlAnalysis.referencedInlineContentIDs, ["cid-sent"])
        XCTAssertEqual(viewModel.sharedDocumentLinks.map(\.id), ["link-cid-sent"])
        XCTAssertEqual(viewModel.forwardedDisplayContent?.subject, "Forwarded cid-sent")

        await loader.release()
        await refresh.value

        XCTAssertEqual(viewModel.fullTextContent, "Refreshed sent body")
        XCTAssertEqual(viewModel.sharedDocumentLinks.map(\.id), ["link-cid-sent-2"])
        let senderCallCount = await loader.senderCallCount()
        XCTAssertEqual(senderCallCount, 0)
    }

    /// The early-return branch records the requested signature even when it skips loading, so a
    /// refresh that is still in flight when the signature returns to the published one is dropped
    /// by `isStillActive` instead of overwriting what is already correct on screen.
    func testLoadIfNeeded_discardsSupersededRefreshWhenSignatureReturnsToPublishedOne() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(name: "Published Name", avatarURL: nil, imageData: nil),
                MessageBubbleSenderResult(name: "Superseded Name", avatarURL: nil, imageData: nil)
            ],
            contentResults: [
                Self.makeContentResult(text: "Published body", inlineContentID: "cid-published"),
                Self.makeContentResult(text: "Superseded body", inlineContentID: "cid-superseded")
            ],
            gatedCallIndex: 2
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(using: makeContext(signature: "sig-a", hasHTMLSource: true))

        let superseded = Task {
            await viewModel.loadIfNeeded(using: self.makeContext(signature: "sig-b", hasHTMLSource: true))
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated refresh never started")

        // The signature settles back on the one already published, so this call short-circuits.
        await viewModel.loadIfNeeded(using: makeContext(signature: "sig-a", hasHTMLSource: true))

        await loader.release()
        await superseded.value

        XCTAssertEqual(viewModel.fullTextContent, "Published body")
        XCTAssertEqual(viewModel.senderName, "Published Name")
        XCTAssertEqual(viewModel.htmlAnalysis.referencedInlineContentIDs, ["cid-published"])
    }

    /// On an in-place refresh the sender is committed together with the content, not as soon as it
    /// resolves. A refresh cancelled between the two must therefore leave the OLD sender on screen:
    /// publishing it early would put the new signature's sender under an `appliedContentSignature`
    /// that still named the old one, and the early-return guard would then strand that mismatch.
    func testLoadIfNeeded_doesNotCommitSenderBeforeContentOnInPlaceRefresh() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(
                    name: "Old Contact Name",
                    avatarURL: "file:///old-avatar",
                    imageData: Data([0x01])
                ),
                MessageBubbleSenderResult(
                    name: "Updated Contact Name",
                    avatarURL: "file:///new-avatar",
                    imageData: Data([0x02])
                )
            ],
            contentResults: [
                Self.makeContentResult(text: "Tall HTML body", inlineContentID: "cid-old"),
                Self.makeContentResult(text: "Refreshed body", inlineContentID: "cid-new")
            ],
            gatedSenderCallIndex: 2,
            gatedContentCallIndex: 2
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(using: makeContext(signature: "sig-1|contacts:0", hasHTMLSource: true))

        let refresh = Task {
            await viewModel.loadIfNeeded(using: self.makeContext(signature: "sig-1|contacts:1", hasHTMLSource: true))
        }
        let senderGateEntered = await loader.waitForSenderGateEntry()
        XCTAssertTrue(senderGateEntered, "gated sender load never started")

        // Hand the view model its new sender result while the content load stays parked, then give
        // it time to act on it. An eager publish lands in microseconds; a deferred one never lands.
        await loader.releaseSender()
        try? await Task.sleep(nanoseconds: 100_000_000)

        refresh.cancel()
        await loader.releaseContent()
        await refresh.value

        // The refresh committed nothing, so the whole bubble — sender included — is untouched.
        XCTAssertEqual(viewModel.senderName, "Old Contact Name")
        XCTAssertEqual(viewModel.senderAvatarURL, "file:///old-avatar")
        XCTAssertEqual(viewModel.senderImageData, Data([0x01]))
        XCTAssertEqual(viewModel.fullTextContent, "Tall HTML body")
    }

    private static func makeContentResult(
        text: String,
        inlineContentID: String
    ) -> MessageBubbleContentResult {
        MessageBubbleContentResult(
            fullTextContent: text,
            hasRichHTMLContent: true,
            sharedDocumentLinks: [
                SharedDocumentLink(
                    id: "link-\(inlineContentID)",
                    url: URL(string: "https://docs.google.com/document/d/\(inlineContentID)/edit")!,
                    kind: .googleDoc
                )
            ],
            forwardedDisplayContent: ForwardedMessageDisplayContent(
                leadInText: text,
                senderDisplayName: nil,
                senderEmail: nil,
                subject: "Forwarded \(inlineContentID)",
                timestampText: nil,
                recipientSummary: nil,
                previewSnippet: nil
            ),
            htmlAnalysis: MessageBubbleHTMLAnalysis(
                hasHTMLSource: true,
                referencedInlineContentIDs: [inlineContentID],
                nonDisplayableInlineContentIDs: [],
                supportsCalendarInvitePreviewCard: false
            )
        )
    }

    private func makeContext(
        messageID: String = "msg-1",
        signature: String = "sig-1",
        senderEmail: String = "alice@example.com",
        hasHTMLSource: Bool = false,
        includesSenderRequest: Bool = true
    ) -> MessageBubbleLoadContext {
        MessageBubbleLoadContext(
            messageID: messageID,
            contentSignature: signature,
            prefetchedSenderName: "Prefetched Name",
            senderRequest: includesSenderRequest ? MessageBubbleSenderRequest(
                email: senderEmail,
                personDisplayName: nil,
                personAvatarURL: "file:///person-avatar"
            ) : nil,
            contentRequest: MessageBubbleContentRequest(
                messageID: messageID,
                bodyText: "Body",
                bodyStorageURI: nil,
                cleanedSnippet: "Cleaned snippet",
                snippet: "Snippet",
                subject: "Subject",
                senderName: "Alice Example",
                hasHTMLSource: hasHTMLSource,
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

/// Loader whose Nth sender *and* content load park until the test releases them, so the view
/// model's published state can be observed while a refresh is genuinely in flight. Gating the
/// sender load matters: the view model awaits it before the content load, so that await is where
/// it parks — and only a parked sender load lets the test assert sender-identity retention.
actor GatedMessageBubbleLoader: MessageBubbleLoading {
    private var senderResults: [MessageBubbleSenderResult]
    private var contentResults: [MessageBubbleContentResult]
    private let gatedSenderCallIndex: Int?
    private let gatedContentCallIndex: Int?

    private var senderCalls = 0
    private var contentCalls = 0
    private var senderReleased = false
    private var contentReleased = false
    private var senderReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var contentReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var senderGateEntered = false
    private var contentGateEntered = false

    init(
        senderResults: [MessageBubbleSenderResult],
        contentResults: [MessageBubbleContentResult],
        gatedSenderCallIndex: Int?,
        gatedContentCallIndex: Int?
    ) {
        self.senderResults = senderResults
        self.contentResults = contentResults
        self.gatedSenderCallIndex = gatedSenderCallIndex
        self.gatedContentCallIndex = gatedContentCallIndex
    }

    /// Gates the sender and content loads of the same call index together — the common case,
    /// where the test only needs the view model parked somewhere inside one refresh.
    init(
        senderResults: [MessageBubbleSenderResult],
        contentResults: [MessageBubbleContentResult],
        gatedCallIndex: Int
    ) {
        self.init(
            senderResults: senderResults,
            contentResults: contentResults,
            gatedSenderCallIndex: gatedCallIndex,
            gatedContentCallIndex: gatedCallIndex
        )
    }

    func loadSenderInfo(from request: MessageBubbleSenderRequest) async -> MessageBubbleSenderResult {
        senderCalls += 1
        if senderCalls == gatedSenderCallIndex {
            senderGateEntered = true
            await waitForSenderRelease()
        }
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
        if contentCalls == gatedContentCallIndex {
            contentGateEntered = true
            await waitForContentRelease()
        }
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

    /// Suspends until a gated load has parked, i.e. until the view model is provably past the
    /// synchronous prologue of `loadIfNeeded` and — because the gated call cannot return until
    /// `release()` — unable to publish anything further.
    ///
    /// Returns false instead of suspending forever if the gated load never happens: a regression
    /// that stops issuing the second load must turn a test red, not hang the suite (this repo has
    /// lost whole CI jobs to tests that wait on something that never arrives).
    func waitForGateEntry(timeout: TimeInterval = 5) async -> Bool {
        await waitUntilEntered(.either, timeout: timeout)
    }

    func waitForSenderGateEntry(timeout: TimeInterval = 5) async -> Bool {
        await waitUntilEntered(.sender, timeout: timeout)
    }

    func release() {
        releaseSender()
        releaseContent()
    }

    func releaseSender() {
        senderReleased = true
        let waiters = senderReleaseWaiters
        senderReleaseWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func releaseContent() {
        contentReleased = true
        let waiters = contentReleaseWaiters
        contentReleaseWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func senderCallCount() -> Int {
        senderCalls
    }

    func contentCallCount() -> Int {
        contentCalls
    }

    private func waitForSenderRelease() async {
        if senderReleased {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            senderReleaseWaiters.append(continuation)
        }
    }

    private func waitForContentRelease() async {
        if contentReleased {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            contentReleaseWaiters.append(continuation)
        }
    }

    private enum Gate {
        case sender
        case either
    }

    private func waitUntilEntered(_ gate: Gate, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch gate {
            case .sender where senderGateEntered:
                return true
            case .either where senderGateEntered || contentGateEntered:
                return true
            default:
                break
            }
            if Date() >= deadline {
                return false
            }
            // Deliberately tolerant of cancellation: the deadline, not the sleep, bounds this loop.
            try? await Task.sleep(nanoseconds: 500_000)
        }
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

    func testResolvedVisibleText_prefersChatPreviewBeforeLoadedCompatibilityText() throws {
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
                chatPreviewText: "Canonical chat preview"
            )
        )

        XCTAssertEqual(result, "Canonical chat preview")
    }

    func testResolvedVisibleText_usesLoadedCompatibilityTextWhenChatPreviewMissing() throws {
        let result = try XCTUnwrap(
            MessageContentView.resolvedVisibleText(
                fullTextContent: "Loaded compatibility text",
                fallbackPreviewText: "Legacy compact fallback",
                chatPreviewText: nil
            )
        )

        XCTAssertEqual(result, "Loaded compatibility text")
    }

    func testResolvedVisibleText_usesLegacyFallbackWhenChatPreviewAndLoadedTextMissing() throws {
        let result = try XCTUnwrap(
            MessageContentView.resolvedVisibleText(
                fullTextContent: nil,
                fallbackPreviewText: "Legacy compact fallback",
                chatPreviewText: nil
            )
        )

        XCTAssertEqual(result, "Legacy compact fallback")
    }

    func testResolvedVisibleText_prefersChatPreviewBeforeLegacyFallback() throws {
        let result = try XCTUnwrap(
            MessageContentView.resolvedVisibleText(
                fullTextContent: nil,
                fallbackPreviewText: "Legacy compact fallback",
                chatPreviewText: "Canonical chat preview\n\nSecond line"
            )
        )

        XCTAssertEqual(result, "Canonical chat preview\n\nSecond line")
    }

    func testResolvedVisibleText_ignoresBlankChatPreviewBeforeLegacyFallback() throws {
        let result = try XCTUnwrap(
            MessageContentView.resolvedVisibleText(
                fullTextContent: nil,
                fallbackPreviewText: "Legacy compact fallback",
                chatPreviewText: " \n\t "
            )
        )

        XCTAssertEqual(result, "Legacy compact fallback")
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
                sharedDocumentLinks: [link]
            )
        )

        XCTAssertEqual(result, "Here is the doc:")
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

final class OriginalEmailLoadIdentityTests: XCTestCase {
    func testBaseLoadKeyDoesNotChangeWhenStoredHTMLChangesWithSameURI() throws {
        let messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OriginalEmailLoadIdentity-\(UUID().uuidString)", isDirectory: true)
        let handler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        let messageId = "original-load-key-change"
        defer {
            handler.deleteHTML(for: messageId)
            try? FileManager.default.removeItem(at: messagesDirectory)
        }

        let oldURL = try XCTUnwrap(handler.saveHTML("<html><body><p>OLD_TOKEN</p></body></html>", for: messageId))
        let firstSourceSignature = handler.htmlSourceSignature(
            messageId: messageId,
            bodyStorageURI: oldURL.absoluteString
        )
        let firstIdentity = OriginalEmailLoadIdentity.make(
            messageId: messageId,
            bodyStorageURI: oldURL.absoluteString,
            bodyText: "Stable text",
            subject: "Stable subject",
            senderEmail: "sender@example.com"
        )

        _ = handler.saveHTML("<html><body><p>NEW_TOKEN_WITH_LONGER_SOURCE</p></body></html>", for: messageId)
        let secondSourceSignature = handler.htmlSourceSignature(
            messageId: messageId,
            bodyStorageURI: oldURL.absoluteString
        )
        let secondIdentity = OriginalEmailLoadIdentity.make(
            messageId: messageId,
            bodyStorageURI: oldURL.absoluteString,
            bodyText: "Stable text",
            subject: "Stable subject",
            senderEmail: "sender@example.com"
        )

        XCTAssertNotEqual(firstSourceSignature, secondSourceSignature)
        XCTAssertEqual(firstIdentity.baseLoadKey, secondIdentity.baseLoadKey)
    }

    func testBaseLoadKeyDoesNotChangeWhenRawSourceExtractionCreatesMessageFile() throws {
        let messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OriginalEmailLoadIdentity-\(UUID().uuidString)", isDirectory: true)
        let handler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        let messageId = "original-load-key-raw-source"
        defer {
            handler.deleteHTML(for: messageId)
            try? FileManager.default.removeItem(at: messagesDirectory)
        }

        let rawBodyText = """
        MIME-Version: 1.0
        Content-Type: text/html; charset=UTF-8

        <html><body><p>RAW_SOURCE_TOKEN</p></body></html>
        """
        let missingSourceSignature = handler.htmlSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil
        )
        let firstIdentity = OriginalEmailLoadIdentity.make(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: rawBodyText,
            subject: "Stable subject",
            senderEmail: "sender@example.com"
        )

        _ = handler.saveHTML("<html><body><p>RAW_SOURCE_TOKEN</p></body></html>", for: messageId)
        let savedSourceSignature = handler.htmlSourceSignature(
            messageId: messageId,
            bodyStorageURI: nil
        )
        let secondIdentity = OriginalEmailLoadIdentity.make(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: rawBodyText,
            subject: "Stable subject",
            senderEmail: "sender@example.com"
        )

        XCTAssertEqual(missingSourceSignature, "missing")
        XCTAssertNotEqual(missingSourceSignature, savedSourceSignature)
        XCTAssertEqual(firstIdentity.baseLoadKey, secondIdentity.baseLoadKey)
    }

    func testBaseLoadKeyChangesWhenModelInputsChange() throws {
        let messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OriginalEmailLoadIdentity-\(UUID().uuidString)", isDirectory: true)
        let handler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        let messageId = "original-load-key-input-change"
        defer {
            handler.deleteHTML(for: messageId)
            try? FileManager.default.removeItem(at: messagesDirectory)
        }

        let oldURL = try XCTUnwrap(handler.saveHTML("<html><body><p>SAME_TOKEN</p></body></html>", for: messageId))
        let firstIdentity = OriginalEmailLoadIdentity.make(
            messageId: messageId,
            bodyStorageURI: oldURL.absoluteString,
            bodyText: "Stable text",
            subject: "Stable subject",
            senderEmail: "sender@example.com"
        )

        let bodyTextIdentity = OriginalEmailLoadIdentity.make(
            messageId: messageId,
            bodyStorageURI: oldURL.absoluteString,
            bodyText: "Updated text",
            subject: "Stable subject",
            senderEmail: "sender@example.com"
        )

        XCTAssertNotEqual(firstIdentity.baseLoadKey, bodyTextIdentity.baseLoadKey)
    }
}
