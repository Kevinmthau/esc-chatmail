import Foundation
import Combine

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
    @Published private(set) var hasResolvedHTMLAnalysis = false
    /// Counts changes of the HTML source on disk of the message this view model last loaded for
    /// (`loadingMessageID`), as `HTMLContentLoader.contentSourceDidChangeNotification` reports
    /// them: a recovered body, a raw-source extraction, a sync update that rewrote the file.
    /// The bubble's load signature carries it (`MessageBubbleLoadSignatureComponents.signature`),
    /// so such a change reloads this row and no other (architecture review 2026-11,
    /// chat-transcript-ui#4). It replaced a read of the file's signature in every pass of the
    /// bubble's body, which took the process-wide HTML lock on the main thread and, on a cache
    /// miss, a stat, and which noticed a change only when something else re-ran the body. Per
    /// row, here, never on the transcript's session or scroll state, which would redraw every
    /// row. Starts at 0 and moves only on a change, so a row's first load is not repeated when
    /// a cache fills (a placeholder that turned into the real value would load every row twice).
    /// What fails silently: a new writer of a stored message's HTML that posts nothing leaves a
    /// mounted row on its old content until the row next changes (`postContentSourceDidChange`).
    @Published private(set) var sourceRevision = 0

    private let loader: any MessageBubbleLoading
    private var contentSourceObserver: AnyCancellable?
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

    /// A fresh mount reuses resolved attachment filtering and sizing before its first body
    /// pass. A cache miss still seeds the HTML-source hint, without doing file or parser work.
    /// Analysis alone is not completed content: rich routing and text still await the load.
    init(
        loader: any MessageBubbleLoading,
        initialHasHTMLSource: Bool = false,
        initialContentRequest: MessageBubbleContentRequest? = nil
    ) {
        self.loader = loader
        let cachedAnalysis = initialContentRequest.flatMap { loader.cachedHTMLAnalysis(for: $0) }
        self.htmlAnalysis = cachedAnalysis ?? .placeholder(
            hasHTMLSource: initialContentRequest?.hasHTMLSource ?? initialHasHTMLSource
        )
        self.hasResolvedHTMLAnalysis = cachedAnalysis != nil
        // Posted on the main actor (`HTMLContentLoader.postContentSourceDidChange`), so the
        // sink runs there, in the poster's turn.
        contentSourceObserver = NotificationCenter.default
            .publisher(for: HTMLContentLoader.contentSourceDidChangeNotification)
            .sink { [weak self] notification in
                self?.handleContentSourceDidChange(notification)
            }
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
            // Revalidate the exact source and attachment variant. A warm remount keeps the
            // same filtering/compact-image decisions before and during its async load.
            let cachedAnalysis = loader.cachedHTMLAnalysis(for: context.contentRequest)
            htmlAnalysis = cachedAnalysis ?? .placeholder(hasHTMLSource: context.contentRequest.hasHTMLSource)
            hasResolvedHTMLAnalysis = cachedAnalysis != nil
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
        hasResolvedHTMLAnalysis = true
        hasLoadedContent = true
        appliedContentSignature = context.contentSignature
    }

    /// Bumps `sourceRevision` for a change of the message this view model last loaded for.
    /// Before its first load it has none and ignores every post: that load reads the source as
    /// it is then. After Gmail's echo replaces an optimistic reply under this view model, the
    /// echo's own load (its message ID is part of the bubble's task identity) sets the ID.
    private func handleContentSourceDidChange(_ notification: Notification) {
        guard let loadingMessageID,
              let changedMessageID = notification.userInfo?[
                HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey
              ] as? String,
              changedMessageID == loadingMessageID else {
            return
        }
        sourceRevision &+= 1
    }

    private func isStillActive(_ context: MessageBubbleLoadContext) -> Bool {
        guard !Task.isCancelled else { return false }
        return loadingMessageID == context.messageID && lastContentSignature == context.contentSignature
    }
}
