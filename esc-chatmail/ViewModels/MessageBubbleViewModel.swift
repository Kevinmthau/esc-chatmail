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
    @Published private(set) var htmlAnalysis: MessageBubbleHTMLAnalysis = .empty

    private let loader: any MessageBubbleLoading
    private var loadingMessageID: String?
    /// Signature of the most recently *requested* load. Gates late results in `isStillActive`.
    private var lastContentSignature: String?
    /// Signature whose result was actually *published*. Distinct from `lastContentSignature`
    /// because an in-place refresh keeps the previous content on screen: if that refresh is
    /// cancelled or superseded before `apply`, the published content still belongs to the older
    /// signature, and the next `loadIfNeeded` must retry rather than short-circuit on stale content.
    private var appliedContentSignature: String?

    init(loader: any MessageBubbleLoading) {
        self.loader = loader
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
        let refreshesInPlace = hasLoadedContent && loadingMessageID == context.messageID

        loadingMessageID = context.messageID
        lastContentSignature = context.contentSignature

        if !refreshesInPlace {
            hasLoadedContent = false
            fullTextContent = nil
            hasRichHTMLContent = false
            sharedDocumentLinks = []
            forwardedDisplayContent = nil
            htmlAnalysis = .placeholder(hasHTMLSource: context.contentRequest.hasHTMLSource)
        }

        if let senderRequest = context.senderRequest {
            if !refreshesInPlace {
                senderName = context.prefetchedSenderName
                senderAvatarURL = nil
                senderImageData = nil
            }

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
            guard isStillActive(context) else { return }
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

        // No sender load will run, so publish the terminal sender state now even on an in-place
        // refresh — retaining it would strand an avatar with nothing left to replace it.
        senderName = context.prefetchedSenderName
        senderAvatarURL = nil
        senderImageData = nil

        let contentResult = await loader.loadContent(from: context.contentRequest)
        guard isStillActive(context) else { return }
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
