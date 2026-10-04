import Foundation

@MainActor
final class MessageBubbleViewModel: ObservableObject {
    @Published private(set) var senderName: String?
    @Published private(set) var senderAvatarURL: String?
    @Published private(set) var senderImageData: Data?
    @Published private(set) var hasRichHTMLContent = false
    @Published private(set) var fullTextContent: String?
    @Published private(set) var hasLoadedContent = false
    @Published private(set) var sharedDocumentLinks: [SharedDocumentLink] = []
    @Published private(set) var forwardedDisplayContent: ForwardedMessageDisplayContent?
    @Published private(set) var htmlAnalysis: MessageBubbleHTMLAnalysis

    private let loader: any MessageBubbleLoading
    private var loadingMessageID: String?
    /// `MessageBubbleLoadContext.displayIdentityKey` of the most recently requested load.
    private var loadingDisplayIdentityKey: String?
    /// Signature of the most recently *requested* load. Gates late results in `isStillActive`.
    private var lastContentSignature: String?
    /// Signature whose result was actually *published*. Distinct from `lastContentSignature`
    /// because an in-place refresh keeps the previous content on screen: if that refresh is
    /// incomplete, cancelled, or superseded before `apply`, the published content still belongs to the older
    /// signature, and the next `loadIfNeeded` must retry rather than short-circuit on stale content.
    private var appliedContentSignature: String?

    /// - Parameter initialHasHTMLSource: the row's HTML-source hint
    ///   (`ChatMessageRowModel.hasHTMLSource`), the same value `loadIfNeeded` publishes in its
    ///   synchronous prologue. The bubble's body runs before its `.task` has started that load,
    ///   and routes on `htmlAnalysis` (`MessageBubble.displayInput`): unseeded, every HTML row
    ///   was laid out as a row with no HTML source until then (its text), and swapped to the
    ///   "Loading..." pill or the preview card once the prologue ran; on a chat open, inside the
    ///   hidden initial-anchor pass (`ChatMessagesCoordinator`). Seeded, a fresh mount starts in
    ///   the mid-load state. Only a fresh view model takes the seed: an in-place refresh (Gmail's
    ///   echo replacing an optimistic reply) keeps this instance and what it has published.
    init(loader: any MessageBubbleLoading, initialHasHTMLSource: Bool = false) {
        self.loader = loader
        self.htmlAnalysis = .placeholder(hasHTMLSource: initialHasHTMLSource)
    }

    convenience init(deps: Dependencies) {
        self.init(loader: deps.makeMessageBubbleLoader())
    }

    func loadIfNeeded(using context: MessageBubbleLoadContext) async {
        if hasLoadedContent,
           loadingMessageID == context.messageID,
           appliedContentSignature == context.contentSignature {
            // Already showing this exact signature. Still record it as the wanted one so any
            // older load that is somehow still in flight is discarded by `isStillActive`.
            lastContentSignature = context.contentSignature
            return
        }

        // A signature change for the message already on screen — contact-refresh bump, sender-name
        // change, bodyStorageURI backfill, HTML-source drift — refreshes in place: the published
        // content stays visible until `apply` swaps the new result in atomically. Blanking it here
        // would collapse a tall HTML-source bubble to the ~40pt "Loading..." pill and regrow it
        // asynchronously, shifting chat scroll position. Mirrors EmailContentSection, which keeps
        // `renderedPreview` on screen across background reloads.
        //
        // Keyed on the display identity, not the message ID, so Gmail's echo replacing the user's
        // optimistic reply (a new message ID under the same transcript identity, which keeps this
        // view model alive — `ChatMessageDisplayIdentity`) is such a refresh too: the sent text
        // stays until the echo's content swaps in. `isStillActive` still compares message IDs, so
        // a load still in flight for the optimistic row cannot publish over the echo.
        let refreshesInPlace = hasLoadedContent &&
            loadingDisplayIdentityKey == context.displayIdentityKey

        loadingMessageID = context.messageID
        loadingDisplayIdentityKey = context.displayIdentityKey
        lastContentSignature = context.contentSignature

        if !refreshesInPlace {
            hasLoadedContent = false
            fullTextContent = nil
            hasRichHTMLContent = false
            sharedDocumentLinks = []
            forwardedDisplayContent = nil
            htmlAnalysis = .placeholder(hasHTMLSource: context.contentRequest.hasHTMLSource)
            senderName = context.prefetchedSenderName
            senderAvatarURL = nil
            senderImageData = nil
        }

        if let senderRequest = context.senderRequest {
            async let senderResult = loader.loadSenderInfo(from: senderRequest)
            async let contentResult = loader.loadContent(from: context.contentRequest)

            let loadedSender = await senderResult
            guard isStillActive(context) else { return }
            if !refreshesInPlace {
                // Nothing is published for this message yet, so show the sender the moment it
                // resolves rather than leaving the row nameless until content finishes.
                applySender(loadedSender, for: context)
            }

            let loadedContent = await contentResult
            guard isStillActive(context), loadedContent.isComplete else { return }
            if refreshesInPlace {
                // Held back so the refresh commits as one unit with the content below. Publishing
                // it earlier would put the new signature's sender on screen while
                // `appliedContentSignature` still named the old one — and a cancellation in that
                // window would strand the mismatch behind the early-return guard.
                applySender(loadedSender, for: context)
            }
            apply(loadedContent, for: context)
            return
        }

        let contentResult = await loader.loadContent(from: context.contentRequest)
        guard isStillActive(context), contentResult.isComplete else { return }
        // Publish the terminal sender with completed content; an incomplete refresh keeps both.
        senderName = context.prefetchedSenderName
        senderAvatarURL = nil
        senderImageData = nil
        apply(contentResult, for: context)
    }

    private func applySender(
        _ senderResult: MessageBubbleSenderResult,
        for context: MessageBubbleLoadContext
    ) {
        senderName = senderResult.name ?? context.prefetchedSenderName
        senderAvatarURL = senderResult.avatarURL
        senderImageData = senderResult.imageData
    }

    private func apply(_ contentResult: MessageBubbleContentResult, for context: MessageBubbleLoadContext) {
        fullTextContent = contentResult.fullTextContent
        hasRichHTMLContent = contentResult.hasRichHTMLContent
        sharedDocumentLinks = contentResult.sharedDocumentLinks
        forwardedDisplayContent = contentResult.forwardedDisplayContent
        htmlAnalysis = contentResult.htmlAnalysis
        hasLoadedContent = true
        appliedContentSignature = context.contentSignature
    }

    private func isStillActive(_ context: MessageBubbleLoadContext) -> Bool {
        guard !Task.isCancelled else { return false }
        return loadingMessageID == context.messageID && lastContentSignature == context.contentSignature
    }
}
