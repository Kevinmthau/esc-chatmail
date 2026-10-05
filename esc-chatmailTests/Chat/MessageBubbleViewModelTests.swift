import XCTest
@testable import esc_chatmail

@MainActor
final class MessageBubbleViewModelTests: XCTestCase {
    // MARK: - Initial state

    /// The bubble's first body pass runs before its `.task` has started the load, and reads the
    /// view model as it was created. Created with the row's HTML-source hint, a fresh view model
    /// publishes what `loadIfNeeded`'s prologue publishes for that row, so the first pass sees
    /// the state every pass sees until the load lands. The seed is the hint and nothing else: no
    /// load has run, so the calendar-invite verdict and the inline content IDs are still unknown.
    ///
    /// The parked load carries no prefetched sender name, as in the transcript, where
    /// `ChatMessagesView` passes none.
    ///
    /// Revert-check: seeding `htmlAnalysis` with `.empty` in `MessageBubbleViewModel.init`
    /// (ignoring `initialHasHTMLSource`) fails the first assertion and the comparison with the
    /// parked load.
    func testInit_withHTMLSourceHint_publishesWhatTheLoadProloguePublishes() async {
        let loader = GatedMessageBubbleLoader(senderResults: [], contentResults: [], gatedCallIndex: 1)
        let viewModel = MessageBubbleViewModel(loader: loader, initialHasHTMLSource: true)

        XCTAssertEqual(viewModel.htmlAnalysis, .placeholder(hasHTMLSource: true))
        XCTAssertFalse(viewModel.hasLoadedContent)
        let senderCallCount = await loader.senderCallCount()
        let contentCallCount = await loader.contentCallCount()
        XCTAssertEqual(senderCallCount, 0, "creating the view model must not start a load")
        XCTAssertEqual(contentCallCount, 0, "creating the view model must not start a load")
        let stateBeforeLoad = publishedState(of: viewModel)

        let load = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(hasHTMLSource: true, prefetchedSenderName: nil)
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated load never started")

        XCTAssertEqual(publishedState(of: viewModel), stateBeforeLoad)

        await loader.release()
        await load.value
        XCTAssertTrue(viewModel.hasLoadedContent)
    }

    /// Without a hint (a row with no HTML source, and every caller that passes none) a fresh view
    /// model starts as `.empty`, as it did before the seed existed.
    ///
    /// Revert-check: seeding `htmlAnalysis` with `.placeholder(hasHTMLSource: true)` whatever the
    /// hint, or defaulting `initialHasHTMLSource` to true, in `MessageBubbleViewModel.init` fails
    /// this test.
    func testInit_withoutHTMLSourceHint_startsEmpty() {
        let loader = MockMessageBubbleLoader(senderResults: [], contentResults: [])

        XCTAssertEqual(MessageBubbleViewModel(loader: loader).htmlAnalysis, .empty)
        XCTAssertEqual(
            MessageBubbleViewModel(loader: loader, initialHasHTMLSource: false).htmlAnalysis,
            .empty
        )
    }

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

    func testLoadIfNeeded_incompleteInitialContentRemainsRetryableForSameSignature() async {
        let loader = MockMessageBubbleLoader(
            senderResults: [],
            contentResults: [
                MessageBubbleContentResult(
                    fullTextContent: "Incomplete body",
                    hasRichHTMLContent: false,
                    sharedDocumentLinks: [],
                    forwardedDisplayContent: nil,
                    htmlAnalysis: .placeholder(hasHTMLSource: true),
                    isComplete: false
                ),
                Self.makeContentResult(text: "Recovered body", inlineContentID: "cid-recovered")
            ]
        )
        let viewModel = MessageBubbleViewModel(loader: loader)
        let context = makeContext(hasHTMLSource: true, includesSenderRequest: false)

        await viewModel.loadIfNeeded(using: context)

        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertNil(viewModel.fullTextContent)
        XCTAssertEqual(viewModel.htmlAnalysis, .placeholder(hasHTMLSource: true))

        await viewModel.loadIfNeeded(using: context)

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.fullTextContent, "Recovered body")
        XCTAssertEqual(viewModel.htmlAnalysis.referencedInlineContentIDs, ["cid-recovered"])

        await viewModel.loadIfNeeded(using: context)

        let contentCallCount = await loader.contentCallCount()
        XCTAssertEqual(contentCallCount, 2, "Only a complete result should suppress a same-signature retry")
    }

    func testLoadIfNeeded_incompleteRefreshPreservesPublishedStateAndCanRetrySameSignature() async {
        let originalContent = Self.makeContentResult(text: "Original body", inlineContentID: "cid-original")
        let recoveredContent = Self.makeContentResult(text: "Recovered body", inlineContentID: "cid-recovered")
        let loader = MockMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(
                    name: "Original Name", avatarURL: "file:///original-avatar", imageData: Data([0x01])
                ),
                MessageBubbleSenderResult(
                    name: "Incomplete Name", avatarURL: "file:///incomplete-avatar", imageData: Data([0x02])
                ),
                MessageBubbleSenderResult(
                    name: "Recovered Name", avatarURL: "file:///recovered-avatar", imageData: Data([0x03])
                )
            ],
            contentResults: [
                originalContent,
                MessageBubbleContentResult(
                    fullTextContent: nil,
                    hasRichHTMLContent: false,
                    sharedDocumentLinks: [],
                    forwardedDisplayContent: nil,
                    htmlAnalysis: .placeholder(hasHTMLSource: true),
                    isComplete: false
                ),
                recoveredContent
            ]
        )
        let viewModel = MessageBubbleViewModel(loader: loader)
        let refreshContext = makeContext(signature: "sig-refreshed", hasHTMLSource: true)

        await viewModel.loadIfNeeded(using: makeContext(hasHTMLSource: true))
        await viewModel.loadIfNeeded(using: refreshContext)

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.fullTextContent, originalContent.fullTextContent)
        XCTAssertEqual(viewModel.hasRichHTMLContent, originalContent.hasRichHTMLContent)
        XCTAssertEqual(viewModel.htmlAnalysis, originalContent.htmlAnalysis)
        XCTAssertEqual(viewModel.sharedDocumentLinks, originalContent.sharedDocumentLinks)
        XCTAssertEqual(viewModel.forwardedDisplayContent, originalContent.forwardedDisplayContent)
        XCTAssertEqual(viewModel.senderName, "Original Name")
        XCTAssertEqual(viewModel.senderAvatarURL, "file:///original-avatar")
        XCTAssertEqual(viewModel.senderImageData, Data([0x01]))

        await viewModel.loadIfNeeded(using: refreshContext)

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.fullTextContent, recoveredContent.fullTextContent)
        XCTAssertEqual(viewModel.hasRichHTMLContent, recoveredContent.hasRichHTMLContent)
        XCTAssertEqual(viewModel.htmlAnalysis, recoveredContent.htmlAnalysis)
        XCTAssertEqual(viewModel.sharedDocumentLinks, recoveredContent.sharedDocumentLinks)
        XCTAssertEqual(viewModel.forwardedDisplayContent, recoveredContent.forwardedDisplayContent)
        XCTAssertEqual(viewModel.senderName, "Recovered Name")
        XCTAssertEqual(viewModel.senderAvatarURL, "file:///recovered-avatar")
        XCTAssertEqual(viewModel.senderImageData, Data([0x03]))
        let contentCallCount = await loader.contentCallCount()
        let senderCallCount = await loader.senderCallCount()
        XCTAssertEqual(contentCallCount, 3)
        XCTAssertEqual(senderCallCount, 3)
    }

    func testLoadIfNeeded_incompleteRefreshWithoutSenderRequestKeepsSenderUntilRecovery() async {
        let loader = MockMessageBubbleLoader(
            senderResults: [
                MessageBubbleSenderResult(name: "Original Name", avatarURL: "file:///avatar", imageData: Data([1]))
            ],
            contentResults: [
                Self.makeContentResult(text: "Original body", inlineContentID: "cid-original"),
                MessageBubbleContentResult(
                    fullTextContent: nil, hasRichHTMLContent: false, sharedDocumentLinks: [],
                    forwardedDisplayContent: nil, htmlAnalysis: .empty, isComplete: false
                ),
                Self.makeContentResult(text: "Recovered body", inlineContentID: "cid-recovered")
            ]
        )
        let viewModel = MessageBubbleViewModel(loader: loader)
        let refreshContext = makeContext(signature: "sig-refreshed", includesSenderRequest: false)
        await viewModel.loadIfNeeded(using: makeContext())
        await viewModel.loadIfNeeded(using: refreshContext)

        XCTAssertEqual(viewModel.fullTextContent, "Original body")
        XCTAssertEqual(viewModel.senderName, "Original Name")
        XCTAssertEqual(viewModel.senderAvatarURL, "file:///avatar")
        XCTAssertEqual(viewModel.senderImageData, Data([1]))

        await viewModel.loadIfNeeded(using: refreshContext)

        XCTAssertEqual(viewModel.fullTextContent, "Recovered body")
        XCTAssertEqual(viewModel.senderName, "Prefetched Name")
        XCTAssertNil(viewModel.senderAvatarURL)
        XCTAssertNil(viewModel.senderImageData)
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

    /// Gmail's echo replacing the user's optimistic reply reaches this view model as a new message
    /// ID under the same display identity: the transcript keys rows by
    /// `ChatMessageDisplayIdentity`, so the view (and this view model) survives the swap. It must
    /// refresh in place — the sent text stays on screen until the echo's content swaps in — not
    /// blank to the empty state that renders the "Loading..." pill and collapses the bubble.
    ///
    /// Revert-check: keying `refreshesInPlace` in `MessageBubbleViewModel.loadIfNeeded` on
    /// `loadingMessageID == context.messageID` again clears the content mid-load and fails the
    /// mid-flight assertions.
    func testLoadIfNeeded_echoReplacesOptimisticReplyUnderSameDisplayIdentity_refreshesInPlace() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [],
            contentResults: [
                Self.makeContentResult(text: "Sent body", inlineContentID: "cid-optimistic"),
                Self.makeContentResult(text: "Echo body", inlineContentID: "cid-echo")
            ],
            gatedCallIndex: 2
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(
            using: makeContext(
                messageID: "optimistic-uuid",
                displayIdentityKey: "outbound:optimistic-uuid",
                signature: "sig-optimistic",
                includesSenderRequest: false
            )
        )
        XCTAssertEqual(viewModel.fullTextContent, "Sent body")

        let echoLoad = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(
                    messageID: "gmail-echo-id",
                    displayIdentityKey: "outbound:optimistic-uuid",
                    signature: "sig-echo",
                    hasHTMLSource: true,
                    includesSenderRequest: false
                )
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated echo load never started")

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.fullTextContent, "Sent body")
        XCTAssertEqual(viewModel.htmlAnalysis.referencedInlineContentIDs, ["cid-optimistic"])

        await loader.release()
        await echoLoad.value

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.fullTextContent, "Echo body")
        XCTAssertEqual(viewModel.htmlAnalysis.referencedInlineContentIDs, ["cid-echo"])
    }

    /// The P2 on PR #276: an attachments-only reply flashed "Loading..." when Gmail's echo (HTML
    /// source, no stored preview) replaced it. With the transcript keeping one view across the
    /// echo, the optimistic row's completed load (no text, no HTML source) stays published while
    /// the echo loads, so the text loading placeholder never comes up on this path. Pinned with
    /// the policy's attachments exemption off (`hasDisplayableAttachments: false`), so only the
    /// view model's in-place refresh can keep the pill away; the exemption, which covers fresh
    /// mounts of such rows, is pinned in `MessageDisplayPolicyTests`.
    ///
    /// Revert-check: keying `refreshesInPlace` in `MessageBubbleViewModel.loadIfNeeded` on
    /// `loadingMessageID == context.messageID` again blanks the content mid-load (an HTML-source
    /// placeholder that is not loaded) and fails the mid-flight assertions.
    func testLoadIfNeeded_echoReplacesAttachmentsOnlyReply_neverShowsTextLoadingPlaceholder() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [],
            contentResults: [
                Self.makeTextlessContentResult(hasHTMLSource: false),
                Self.makeTextlessContentResult(hasHTMLSource: true)
            ],
            gatedCallIndex: 2
        )
        let viewModel = MessageBubbleViewModel(loader: loader)
        func showsLoadingPlaceholder() -> Bool {
            MessageDisplayPolicy.showsTextLoadingPlaceholder(
                hasLoadedContent: viewModel.hasLoadedContent,
                routing: MessageDisplayInput(
                    hasHTMLSource: viewModel.htmlAnalysis.hasHTMLSource,
                    isForwardedEmail: false,
                    isNewsletter: false,
                    hasRichHTMLContent: viewModel.hasRichHTMLContent,
                    isFromMe: true,
                    isOneToOneConversation: true,
                    subject: nil,
                    senderEmail: nil
                ),
                // Own rows never consult the verdict, known or not.
                richVerdictIsKnown: false,
                chatPreviewText: nil,
                hasDisplayableAttachments: false
            )
        }

        await viewModel.loadIfNeeded(
            using: makeContext(
                messageID: "optimistic-uuid",
                displayIdentityKey: "outbound:optimistic-uuid",
                signature: "sig-optimistic",
                includesSenderRequest: false
            )
        )
        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertFalse(showsLoadingPlaceholder())

        let echoLoad = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(
                    messageID: "gmail-echo-id",
                    displayIdentityKey: "outbound:optimistic-uuid",
                    signature: "sig-echo",
                    hasHTMLSource: true,
                    includesSenderRequest: false
                )
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated echo load never started")

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertFalse(showsLoadingPlaceholder())

        await loader.release()
        await echoLoad.value

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertTrue(viewModel.htmlAnalysis.hasHTMLSource)
        XCTAssertNil(viewModel.fullTextContent)
        XCTAssertFalse(showsLoadingPlaceholder())
    }

    /// An incoming row with a stored preview and no stored rich-content verdict, sampled the way
    /// the views sample it (`MessageBubble.showHTMLPreview`, then `MessageContentView.textContent`)
    /// on a fresh mount's first pass, before anything has started the load; while its first load
    /// is parked; and again once it lands with a "rich" verdict. A row with a new subject is never
    /// a text bubble before that verdict routes it to the preview card; a reply, which no verdict
    /// routes to a card, is its stored text throughout. Rows that carry a stored verdict are
    /// mirrored in the section below.
    ///
    /// Revert-check: replacing
    /// `!loadCanRouteToHTMLPreview(routing, richVerdictIsKnown: richVerdictIsKnown)` in
    /// `MessageDisplayPolicy.showsTextLoadingPlaceholder` with the flag list it superseded
    /// (`!routing.isNewsletter && !routing.isLikelyCalendarInvite &&
    /// !isTrustedTransactionalSender(routing.senderEmail)`) renders the new-subject row as text
    /// before and during the load: the first-pass and mid-flight
    /// `presentation(subject: "Your receipt")` assertions read `.storedText` instead of
    /// `.loadingPlaceholder`. Seeding `htmlAnalysis` with `.empty` in
    /// `MessageBubbleViewModel.init` (ignoring `initialHasHTMLSource`) does the same to the
    /// first-pass assertion alone.
    ///
    /// HONEST SCOPE: `presentation` mirrors the two view decisions for a non-forwarded row from
    /// the view model's real published state. The views' own composition is not covered (there is
    /// no UI test target). That includes `MessageBubble.init` creating the view model with
    /// `message.hasHTMLSource`: the first-pass sample holds for a view model seeded by hand here.
    func testLoadIfNeeded_incomingStoredPreviewRow_neverRendersTextTheLoadRoutesToCard() async {
        enum Presentation: Equatable {
            case previewCard
            case loadingPlaceholder
            case storedText
        }
        let loader = GatedMessageBubbleLoader(
            senderResults: [],
            contentResults: [
                MessageBubbleContentResult(
                    fullTextContent: "Stored preview",
                    hasRichHTMLContent: true,
                    sharedDocumentLinks: [],
                    forwardedDisplayContent: nil,
                    htmlAnalysis: .placeholder(hasHTMLSource: true)
                )
            ],
            gatedCallIndex: 1
        )
        let viewModel = MessageBubbleViewModel(loader: loader, initialHasHTMLSource: true)
        func presentation(subject: String) -> Presentation {
            let routing = MessageDisplayInput(
                hasHTMLSource: viewModel.htmlAnalysis.hasHTMLSource,
                isForwardedEmail: false,
                isNewsletter: false,
                hasRichHTMLContent: viewModel.hasRichHTMLContent,
                isFromMe: false,
                isOneToOneConversation: true,
                subject: subject,
                senderEmail: "alice@example.com"
            )
            if MessageDisplayPolicy.shouldShowHTMLPreview(routing) {
                return .previewCard
            }
            return MessageDisplayPolicy.showsTextLoadingPlaceholder(
                hasLoadedContent: viewModel.hasLoadedContent,
                routing: routing,
                // No stored verdict: unknown until the load publishes, and once it has, the
                // decision returns on `hasLoadedContent` before it reads this.
                richVerdictIsKnown: false,
                chatPreviewText: "Stored preview",
                hasDisplayableAttachments: false
            ) ? .loadingPlaceholder : .storedText
        }

        // The first body pass: nothing has started the load yet.
        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertEqual(presentation(subject: "Your receipt"), .loadingPlaceholder)
        XCTAssertEqual(presentation(subject: "Re: Dinner"), .storedText)

        let load = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(hasHTMLSource: true, includesSenderRequest: false)
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated load never started")

        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertEqual(presentation(subject: "Your receipt"), .loadingPlaceholder)
        XCTAssertEqual(presentation(subject: "Re: Dinner"), .storedText)

        await loader.release()
        await load.value

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(presentation(subject: "Your receipt"), .previewCard)
        XCTAssertEqual(presentation(subject: "Re: Dinner"), .storedText)
    }

    // MARK: - Stored rich-content verdict (mirrored view decisions)

    private enum MirroredPresentation: Equatable {
        case previewCard
        case loadingPlaceholder
        case storedText
    }

    /// What the bubble shows for an incoming row in a one-to-one conversation that is not a
    /// forward, decided the way the views decide it from the view model's real published state
    /// and the verdict the row stores: the row model's gate on the stored verdict
    /// (`ChatMessageRowModel.knownRichContentVerdict`), then `MessageBubble.resolvedRichVerdict`
    /// feeding `MessageBubble.displayInput` and `MessageBubble.showHTMLPreview`, then
    /// `MessageContentView.textContent` with the known-ness from that same resolution.
    ///
    /// HONEST SCOPE: this mirror reproduces private SwiftUI wiring (`MessageBubble.displayInput`
    /// / `MessageContentView`) that no UI test target covers. It shows the policy functions
    /// compose to the intended presentation over the view model's real state; it cannot notice
    /// the views composing them differently (`displayInput` reading
    /// `viewModel.hasRichHTMLContent` again, or `MessageContentView` handed a known-ness that
    /// did not come from the resolution that built its routing input).
    private func mirroredPresentation(
        of viewModel: MessageBubbleViewModel,
        storedVerdict: RichContentVerdict,
        subject: String,
        chatPreviewText: String? = "Stored preview"
    ) -> MirroredPresentation {
        let resolvedRichVerdict = MessageDisplayPolicy.resolvedRichVerdict(
            hasLoadedContent: viewModel.hasLoadedContent,
            loadedHasRichHTMLContent: viewModel.hasRichHTMLContent,
            knownStoredVerdict: ChatMessageRowModelMapper.knownRichContentVerdict(
                stored: storedVerdict,
                chatPreviewText: chatPreviewText,
                bodyText: nil,
                snippet: nil,
                isFromMe: false,
                isForwardedEmail: false
            )
        )
        let displayInput = MessageDisplayInput(
            hasHTMLSource: viewModel.htmlAnalysis.hasHTMLSource,
            isForwardedEmail: false,
            isNewsletter: false,
            hasRichHTMLContent: resolvedRichVerdict.hasRichHTMLContent,
            isFromMe: false,
            isOneToOneConversation: true,
            subject: subject,
            senderEmail: "alice@example.com"
        )
        if MessageDisplayPolicy.shouldShowHTMLPreview(displayInput) {
            return .previewCard
        }
        return MessageDisplayPolicy.showsTextLoadingPlaceholder(
            hasLoadedContent: viewModel.hasLoadedContent,
            routing: displayInput,
            richVerdictIsKnown: resolvedRichVerdict.isKnown,
            chatPreviewText: chatPreviewText,
            hasDisplayableAttachments: false
        ) ? .loadingPlaceholder : .storedText
    }

    /// A row stamped rich whose subject is not a reply is the preview card from its first pass:
    /// before `loadIfNeeded` has run (the view model seeded with the row's hint, as
    /// `MessageBubble.init` seeds it), while the load is parked, and once it lands. It shows
    /// neither the pill nor its stored text first. A reply stamped rich is its stored text
    /// throughout: the routing keeps an ordinary sender's replies in bubbles whatever the
    /// verdict, and with the verdict known nothing is left for the load to decide.
    ///
    /// Revert-check: dropping the `if let knownStoredVerdict` branch from
    /// `MessageDisplayPolicy.resolvedRichVerdict` (unknown until the load publishes) turns the
    /// first-pass and mid-flight "Your receipt" samples into `.loadingPlaceholder`.
    func testLoadIfNeeded_incomingRowStoredRich_showsPreviewCardBeforeItsLoadPublishes() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [],
            contentResults: [Self.makeStoredPreviewContentResult(hasRichHTMLContent: true)],
            gatedCallIndex: 1
        )
        let viewModel = MessageBubbleViewModel(loader: loader, initialHasHTMLSource: true)

        // First pass: no load has run, and the view model carries only the row's hint.
        XCTAssertTrue(viewModel.htmlAnalysis.hasHTMLSource)
        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .rich, subject: "Your receipt"),
            .previewCard
        )
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .rich, subject: "Re: Dinner"),
            .storedText
        )

        let load = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(hasHTMLSource: true, includesSenderRequest: false)
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated load never started")

        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertTrue(viewModel.htmlAnalysis.hasHTMLSource)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .rich, subject: "Your receipt"),
            .previewCard
        )
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .rich, subject: "Re: Dinner"),
            .storedText
        )

        await loader.release()
        await load.value

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .rich, subject: "Your receipt"),
            .previewCard
        )
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .rich, subject: "Re: Dinner"),
            .storedText
        )
    }

    /// A row stamped not-rich whose subject is not a reply is its stored text from its first
    /// pass, while the load is parked, and once it lands confirming the verdict: no pill, and so
    /// no pill → bubble swap growing the transcript. The same parked row without a stored verdict
    /// waits on the pill, which is what the stored verdict removed.
    ///
    /// Revert-check: ignoring `richVerdictIsKnown` in
    /// `MessageDisplayPolicy.loadCanRouteToHTMLPreview` (trying both verdicts whatever it says),
    /// or dropping the `if let knownStoredVerdict` branch from
    /// `MessageDisplayPolicy.resolvedRichVerdict`, turns the first-pass and mid-flight
    /// `.notRich` samples into `.loadingPlaceholder`.
    func testLoadIfNeeded_incomingRowStoredNotRich_rendersStoredTextBeforeItsLoadPublishes() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [],
            contentResults: [Self.makeStoredPreviewContentResult(hasRichHTMLContent: false)],
            gatedCallIndex: 1
        )
        // Seeded with the row's hint, as `MessageBubble.init` seeds it: the first pass is
        // asked about an HTML row, which without a known verdict would be the pill.
        let viewModel = MessageBubbleViewModel(loader: loader, initialHasHTMLSource: true)

        XCTAssertTrue(viewModel.htmlAnalysis.hasHTMLSource)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .notRich, subject: "Your receipt"),
            .storedText
        )
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .unknown, subject: "Your receipt"),
            .loadingPlaceholder,
            "premise: the same first pass without a stored verdict waits on the pill"
        )

        let load = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(hasHTMLSource: true, includesSenderRequest: false)
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated load never started")

        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertTrue(viewModel.htmlAnalysis.hasHTMLSource)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .notRich, subject: "Your receipt"),
            .storedText
        )
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .unknown, subject: "Your receipt"),
            .loadingPlaceholder,
            "premise: without a stored verdict this parked row waits on the pill"
        )

        await loader.release()
        await load.value

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertFalse(viewModel.hasRichHTMLContent)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .notRich, subject: "Your receipt"),
            .storedText
        )
    }

    /// The load is authoritative once it has published. A row stamped not-rich whose load finds
    /// rich content (a stale stamp: the load evaluates the same rule over the row's current
    /// state) is its stored text only until the load lands, then the preview card.
    /// (`MessageBubbleLoader.loadContent` asks for the stamp to be refreshed.)
    ///
    /// Revert-check: testing `knownStoredVerdict` ahead of `hasLoadedContent` in
    /// `MessageDisplayPolicy.resolvedRichVerdict` leaves the row on `.storedText` after the load.
    func testLoadIfNeeded_storedNotRichThenLoadPublishesRich_loadVerdictRoutesToPreviewCard() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [],
            contentResults: [Self.makeStoredPreviewContentResult(hasRichHTMLContent: true)],
            gatedCallIndex: 1
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        let load = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(hasHTMLSource: true, includesSenderRequest: false)
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated load never started")

        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .notRich, subject: "Your receipt"),
            .storedText
        )

        await loader.release()
        await load.value

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertTrue(viewModel.hasRichHTMLContent)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .notRich, subject: "Your receipt"),
            .previewCard
        )
    }

    /// The other direction of the same rule: a row stamped rich whose load finds none is the
    /// preview card only until the load lands, then its stored text.
    ///
    /// Revert-check: testing `knownStoredVerdict` ahead of `hasLoadedContent` in
    /// `MessageDisplayPolicy.resolvedRichVerdict` leaves the row on `.previewCard` after the
    /// load.
    func testLoadIfNeeded_storedRichThenLoadPublishesNotRich_loadVerdictRoutesToStoredText() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [],
            contentResults: [Self.makeStoredPreviewContentResult(hasRichHTMLContent: false)],
            gatedCallIndex: 1
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        let load = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(hasHTMLSource: true, includesSenderRequest: false)
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated load never started")

        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .rich, subject: "Your receipt"),
            .previewCard
        )

        await loader.release()
        await load.value

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertFalse(viewModel.hasRichHTMLContent)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .rich, subject: "Your receipt"),
            .storedText
        )
    }

    /// An incomplete load is never applied: `hasLoadedContent` stays false while the HTML-source
    /// hint published when the load began still stands. A row without a stored verdict is
    /// stranded on the pill in that state (the closing assertion); a row with one renders its
    /// card or its stored text through it.
    ///
    /// Revert-check: dropping the `if let knownStoredVerdict` branch from
    /// `MessageDisplayPolicy.resolvedRichVerdict` turns both "Your receipt" samples into
    /// `.loadingPlaceholder`; ignoring `richVerdictIsKnown` in
    /// `MessageDisplayPolicy.loadCanRouteToHTMLPreview` does so for the `.notRich` one.
    func testLoadIfNeeded_incompleteLoadWithStoredVerdict_neverShowsLoadingPlaceholder() async {
        let loader = MockMessageBubbleLoader(
            senderResults: [],
            contentResults: [Self.makeIncompleteContentResult()]
        )
        let viewModel = MessageBubbleViewModel(loader: loader)

        await viewModel.loadIfNeeded(using: makeContext(hasHTMLSource: true, includesSenderRequest: false))

        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertTrue(viewModel.htmlAnalysis.hasHTMLSource)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .rich, subject: "Your receipt"),
            .previewCard
        )
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .notRich, subject: "Your receipt"),
            .storedText
        )
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .rich, subject: "Re: Dinner"),
            .storedText
        )
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .notRich, subject: "Re: Dinner"),
            .storedText
        )
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .unknown, subject: "Your receipt"),
            .loadingPlaceholder,
            "premise: without a stored verdict an incomplete load leaves this row on the pill"
        )
    }

    /// A row with no stored verdict behaves as every row did before verdicts were stored: with a
    /// new subject it keeps the pill while its load is parked and through an incomplete load, and
    /// leaves it only when a load publishes. A reply, which no verdict cards, is its stored text
    /// throughout. A row the row model reports as unknown although it stores a verdict keeps the
    /// pill the same way: one with a blank preview, whose load does not publish the stored rule's
    /// answer.
    ///
    /// Revert-check: reporting the fall-through of `MessageDisplayPolicy.resolvedRichVerdict` as
    /// known (`isKnown: true`) renders the new-subject row as `.storedText` mid-flight and after
    /// the incomplete load. Dropping the blank-preview guard from
    /// `ChatMessageRowModelMapper.knownRichContentVerdict` turns the blank-preview sample into
    /// `.previewCard`.
    func testLoadIfNeeded_incomingRowWithoutKnownVerdict_keepsLoadingPlaceholderUntilALoadPublishes() async {
        let loader = GatedMessageBubbleLoader(
            senderResults: [],
            contentResults: [
                Self.makeIncompleteContentResult(),
                Self.makeStoredPreviewContentResult(hasRichHTMLContent: false)
            ],
            gatedCallIndex: 1
        )
        let viewModel = MessageBubbleViewModel(loader: loader)
        let context = makeContext(hasHTMLSource: true, includesSenderRequest: false)

        let load = Task {
            await viewModel.loadIfNeeded(using: context)
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated load never started")

        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .unknown, subject: "Your receipt"),
            .loadingPlaceholder
        )
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .unknown, subject: "Re: Dinner"),
            .storedText
        )
        XCTAssertEqual(
            mirroredPresentation(
                of: viewModel,
                storedVerdict: .rich,
                subject: "Your receipt",
                chatPreviewText: nil
            ),
            .loadingPlaceholder
        )

        await loader.release()
        await load.value

        // The parked load came back incomplete, so nothing was applied.
        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .unknown, subject: "Your receipt"),
            .loadingPlaceholder
        )

        await viewModel.loadIfNeeded(using: context)

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(
            mirroredPresentation(of: viewModel, storedVerdict: .unknown, subject: "Your receipt"),
            .storedText
        )
    }

    /// A row that renders its stored text before its load, sampled the way the views sample it
    /// (`MessageBubble.resolvedSharedDocumentLinks`, then `MessageContentView.resolvedVisibleText`
    /// and its document cards): on a fresh mount's first pass, while the load is parked, and
    /// once it has published. The bubble is the same throughout: the text without the
    /// document's URL, and the document's card. It used to mount showing the raw URL and no
    /// card, and swap when the load published, growing the transcript after mount.
    ///
    /// Revert-check: `MessageDisplayPolicy.sharedDocumentLinks` returning `loaded`
    /// unconditionally (the view model's links, as `MessageBubble` passed before) fails the
    /// first-pass and mid-flight samples, which read the URL in the text and no card.
    ///
    /// HONEST SCOPE: `rendering` mirrors the two view decisions from the view model's real
    /// published state and the links the row would carry. The views' own composition is not
    /// covered (there is no UI test target), in particular `MessageBubble` handing
    /// `resolvedSharedDocumentLinks`, not `viewModel.sharedDocumentLinks`, to
    /// `MessageContentView`. That the real loader publishes what the row carries is pinned in
    /// `MessageBubbleLoaderTests`; the stubbed result here is built by hand.
    func testLoadIfNeeded_storedPreviewRowWithSharedDocumentLink_rendersTextAndCardThroughoutLoad() async throws {
        struct Rendering: Equatable {
            let visibleText: String?
            let cardIDs: [String]
        }
        let chatPreviewText = "Here is the doc: https://docs.google.com/document/d/abc123/edit"
        let url = try XCTUnwrap(URL(string: "https://docs.google.com/document/d/abc123/edit"))
        let loadedLink = SharedDocumentLink(
            id: SharedDocumentLinkExtractor.dedupeKey(for: url, kind: .googleDoc),
            url: url,
            kind: .googleDoc
        )
        let rowLinks = SharedDocumentLinkExtractor.storedRowLinks(
            chatPreviewText: chatPreviewText,
            bodyText: "Body",
            snippet: "Snippet",
            isForwardedEmail: false
        )
        let loader = GatedMessageBubbleLoader(
            senderResults: [],
            contentResults: [
                MessageBubbleContentResult(
                    fullTextContent: chatPreviewText,
                    hasRichHTMLContent: false,
                    sharedDocumentLinks: [loadedLink],
                    forwardedDisplayContent: nil,
                    htmlAnalysis: .placeholder(hasHTMLSource: true)
                )
            ],
            gatedCallIndex: 1
        )
        let viewModel = MessageBubbleViewModel(loader: loader, initialHasHTMLSource: true)
        func rendering() -> Rendering {
            let links = MessageDisplayPolicy.sharedDocumentLinks(
                hasLoadedContent: viewModel.hasLoadedContent,
                loaded: viewModel.sharedDocumentLinks,
                stored: rowLinks
            )
            return Rendering(
                visibleText: MessageContentView.resolvedVisibleText(
                    fullTextContent: viewModel.fullTextContent,
                    fallbackPreviewText: nil,
                    chatPreviewText: chatPreviewText,
                    sharedDocumentLinks: links
                ),
                cardIDs: links.map(\.id)
            )
        }
        let final = Rendering(visibleText: "Here is the doc:", cardIDs: ["googleDoc|abc123"])

        // The first body pass: nothing has started the load yet.
        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertEqual(rendering(), final)

        let load = Task {
            await viewModel.loadIfNeeded(
                using: self.makeContext(hasHTMLSource: true, includesSenderRequest: false)
            )
        }
        let gateEntered = await loader.waitForGateEntry()
        XCTAssertTrue(gateEntered, "gated load never started")

        XCTAssertFalse(viewModel.hasLoadedContent)
        XCTAssertEqual(rendering(), final)

        await loader.release()
        await load.value

        XCTAssertTrue(viewModel.hasLoadedContent)
        XCTAssertEqual(viewModel.sharedDocumentLinks, [loadedLink])
        XCTAssertEqual(rendering(), final)
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

    /// An attachments-only reply's content: no text of its own, nothing else to publish.
    private static func makeTextlessContentResult(hasHTMLSource: Bool) -> MessageBubbleContentResult {
        MessageBubbleContentResult(
            fullTextContent: nil,
            hasRichHTMLContent: false,
            sharedDocumentLinks: [],
            forwardedDisplayContent: nil,
            htmlAnalysis: .placeholder(hasHTMLSource: hasHTMLSource)
        )
    }

    /// What a load publishes for an incoming HTML row with a stored preview: the preview verbatim
    /// as `fullTextContent`, and the rich-content verdict.
    private static func makeStoredPreviewContentResult(hasRichHTMLContent: Bool) -> MessageBubbleContentResult {
        MessageBubbleContentResult(
            fullTextContent: "Stored preview",
            hasRichHTMLContent: hasRichHTMLContent,
            sharedDocumentLinks: [],
            forwardedDisplayContent: nil,
            htmlAnalysis: .placeholder(hasHTMLSource: true)
        )
    }

    /// What an invalidated or unavailable load returns, as the real loader builds it (no HTML
    /// source, incomplete). The view model never applies it, so a test that then reads the
    /// HTML-source hint is reading the one published when the load began.
    private static func makeIncompleteContentResult() -> MessageBubbleContentResult {
        MessageBubbleContentResult(
            fullTextContent: nil,
            hasRichHTMLContent: false,
            sharedDocumentLinks: [],
            forwardedDisplayContent: nil,
            htmlAnalysis: .placeholder(hasHTMLSource: false),
            isComplete: false
        )
    }

    /// Everything a bubble's body reads from its view model.
    private struct PublishedState: Equatable {
        let senderName: String?
        let senderAvatarURL: String?
        let senderImageData: Data?
        let hasRichHTMLContent: Bool
        let fullTextContent: String?
        let hasLoadedContent: Bool
        let sharedDocumentLinks: [SharedDocumentLink]
        let forwardedDisplayContent: ForwardedMessageDisplayContent?
        let htmlAnalysis: MessageBubbleHTMLAnalysis
    }

    private func publishedState(of viewModel: MessageBubbleViewModel) -> PublishedState {
        PublishedState(
            senderName: viewModel.senderName,
            senderAvatarURL: viewModel.senderAvatarURL,
            senderImageData: viewModel.senderImageData,
            hasRichHTMLContent: viewModel.hasRichHTMLContent,
            fullTextContent: viewModel.fullTextContent,
            hasLoadedContent: viewModel.hasLoadedContent,
            sharedDocumentLinks: viewModel.sharedDocumentLinks,
            forwardedDisplayContent: viewModel.forwardedDisplayContent,
            htmlAnalysis: viewModel.htmlAnalysis
        )
    }

    private func makeContext(
        messageID: String = "msg-1",
        displayIdentityKey: String? = nil,
        signature: String = "sig-1",
        senderEmail: String = "alice@example.com",
        hasHTMLSource: Bool = false,
        prefetchedSenderName: String? = "Prefetched Name",
        includesSenderRequest: Bool = true
    ) -> MessageBubbleLoadContext {
        MessageBubbleLoadContext(
            messageID: messageID,
            displayIdentityKey: displayIdentityKey,
            contentSignature: signature,
            prefetchedSenderName: prefetchedSenderName,
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
