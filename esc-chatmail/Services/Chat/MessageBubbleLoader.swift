import Foundation

struct MessageBubbleAccountWorkContext: Sendable {
    let htmlContent: HTMLContentAccountGeneration
    let htmlAnalysis: MessageBubbleHTMLAnalysisAccountGeneration
    let parsedEmail: ParsedEmailAccountGeneration?
    let renderedMessage: RenderedMessageCacheAccountGeneration
    let recovery: HTMLContentRecoveryAccountGeneration
}

/// Deliberately a plain Sendable class, NOT an actor: the loader is stateless
/// (all dependencies are lets; caches synchronize internally), and bubble
/// loads are per-row CPU-bound work (HTML analysis) that must not serialize
/// through a single executor while many bubbles are visible.
/// @unchecked because dependency types predate Sendable annotations; safety
/// holds as long as this class stays free of mutable stored state.
final class MessageBubbleLoader: MessageBubbleLoading, @unchecked Sendable {
    private let contactsResolver: any ContactsResolving
    let htmlContentHandler: HTMLContentHandler
    let htmlContentLoader: HTMLContentLoader
    let htmlContentRecoveryService: any HTMLContentRecovering
    let htmlAnalysisCache: MessageBubbleHTMLAnalysisCache
    let parsedEmailProvider: any ParsedEmailProviding
    let renderedMessageCache: RenderedMessageCache
    let richContentVerdictRefresher: any RichContentVerdictRefreshing

    init(
        contactsResolver: any ContactsResolving = ContactsResolver.shared,
        htmlContentHandler: HTMLContentHandler = .shared,
        htmlContentLoader: HTMLContentLoader = .shared,
        htmlContentRecoveryService: any HTMLContentRecovering = HTMLContentRecoveryService.shared,
        htmlAnalysisCache: MessageBubbleHTMLAnalysisCache = .shared,
        parsedEmailProvider: any ParsedEmailProviding = ParsedEmailProvider.shared,
        renderedMessageCache: RenderedMessageCache = .shared,
        richContentVerdictRefresher: any RichContentVerdictRefreshing = RichContentVerdictRefresher.shared
    ) {
        self.contactsResolver = contactsResolver
        self.htmlContentHandler = htmlContentHandler
        self.htmlContentLoader = htmlContentLoader
        self.htmlContentRecoveryService = htmlContentRecoveryService
        self.htmlAnalysisCache = htmlAnalysisCache
        self.parsedEmailProvider = parsedEmailProvider
        self.renderedMessageCache = renderedMessageCache
        self.richContentVerdictRefresher = richContentVerdictRefresher
    }

    func loadSenderInfo(from request: MessageBubbleSenderRequest) async -> MessageBubbleSenderResult {
        let match = await contactsResolver.lookup(email: request.email)
        let resolvedName = PersonDisplayNameResolver.senderDisplayName(
            email: request.email,
            contactDisplayName: match?.displayName,
            headerDisplayName: request.headerDisplayName,
            storedDisplayName: request.personDisplayName
        )

        let resolvedAvatarURL: String? = match == nil ? request.personAvatarURL : nil

        return MessageBubbleSenderResult(
            name: resolvedName,
            avatarURL: resolvedAvatarURL,
            imageData: match?.imageData
        )
    }

    func loadContent(from request: MessageBubbleContentRequest) async -> MessageBubbleContentResult {
        guard let accountContext = await captureAccountWorkContext() else {
            return unavailableContentResult()
        }
        guard let htmlAnalysis = await loadHTMLAnalysis(for: request, accountContext: accountContext),
              !Task.isCancelled,
              await isAccountWorkContextCurrent(accountContext) else {
            return unavailableContentResult()
        }
        let forwardedDisplayContent = forwardedDisplayContent(from: request)
        let storedChatPreviewText = nonEmptyText(request.chatPreviewText)
        let loadedContent: (plainText: String?, hasRichContent: Bool)
        // The resolver's verdict when this load computed one: the stored-preview branch
        // only. Forwarded rows publish false without classifying, and blank-preview rows
        // use the compatibility path, whose verdict is a different expression (network
        // recovery, no fallback-text term); neither is comparable with the stored verdict.
        var resolvedStoredPreviewVerdict: Bool?
        if forwardedDisplayContent != nil {
            loadedContent = (plainText: nil, hasRichContent: false)
        } else if storedChatPreviewText != nil {
            resolvedStoredPreviewVerdict = await loadRichContentClassification(
                from: request,
                accountContext: accountContext
            )
            // Undetermined (an HTML file that exists but cannot be read) publishes what the
            // row already stores, so a correctly mounted card is not flipped to text by a
            // "not rich" nothing established. With no stored verdict either, it publishes
            // not-rich, as every such load did before verdicts were stored: an incomplete
            // result instead would leave the row on the loading pill for as long as the
            // file stayed unreadable.
            loadedContent = (
                plainText: nil,
                hasRichContent: resolvedStoredPreviewVerdict
                    ?? request.storedRichContentVerdict.isRich
                    ?? false
            )
        } else {
            loadedContent = await loadCompatibilityContent(
                from: request,
                resolvedHasHTMLSource: htmlAnalysis.hasHTMLSource,
                accountContext: accountContext
            )
        }

        guard await isAccountWorkContextCurrent(accountContext) else {
            return unavailableContentResult()
        }

        // The stored verdict is what the bubble rendered before this load, so a difference
        // is a stale or missing stamp: a row the launch backfill has not reached, HTML that
        // changed with no refresh, a classifier change without an epoch bump. Ask for the
        // row to be re-stamped so the next mount agrees. The refresher recomputes from
        // stored state itself; this load's answer is never what gets written. Own rows are
        // skipped: nothing reads their verdict, and optimistic rows are never stamped.
        if let resolvedStoredPreviewVerdict,
           !request.isFromMe,
           RichContentVerdict(isRich: resolvedStoredPreviewVerdict) != request.storedRichContentVerdict {
            richContentVerdictRefresher.scheduleRefresh(
                messageID: request.messageID,
                handler: htmlContentHandler
            )
        }

        let fullTextContent: String?
        if let forwardedDisplayContent {
            fullTextContent = forwardedDisplayContent.leadInText
        } else if let storedChatPreviewText {
            fullTextContent = storedChatPreviewText
        } else {
            fullTextContent = loadedContent.plainText
        }
        let sharedDocumentLinkBodyText = forwardedDisplayContent == nil ? request.bodyText : nil
        let sharedDocumentLinkSnippet = forwardedDisplayContent == nil ? request.snippet : nil

        return MessageBubbleContentResult(
            fullTextContent: fullTextContent,
            hasRichHTMLContent: loadedContent.hasRichContent,
            sharedDocumentLinks: extractSharedDocumentLinks(
                preferredText: fullTextContent,
                bodyText: sharedDocumentLinkBodyText,
                snippet: sharedDocumentLinkSnippet
            ),
            forwardedDisplayContent: forwardedDisplayContent,
            htmlAnalysis: htmlAnalysis
        )
    }

    func captureAccountWorkContext() async -> MessageBubbleAccountWorkContext? {
        guard let htmlContent = htmlContentHandler.captureAccountGeneration(),
              let htmlAnalysis = htmlAnalysisCache.captureAccountGeneration(),
              let renderedMessage = await renderedMessageCache.captureAccountGeneration(),
              let recovery = await htmlContentRecoveryService.captureAccountGeneration() else {
            return nil
        }
        let parsedEmail = await parsedEmailProvider.captureAccountGeneration()

        let context = MessageBubbleAccountWorkContext(
            htmlContent: htmlContent,
            htmlAnalysis: htmlAnalysis,
            parsedEmail: parsedEmail,
            renderedMessage: renderedMessage,
            recovery: recovery
        )
        return await isAccountWorkContextCurrent(context) ? context : nil
    }

    func isAccountWorkContextCurrent(_ context: MessageBubbleAccountWorkContext) async -> Bool {
        guard htmlContentHandler.isAccountGenerationCurrent(context.htmlContent),
              htmlAnalysisCache.isAccountGenerationCurrent(context.htmlAnalysis),
              await renderedMessageCache.isAccountGenerationCurrent(context.renderedMessage),
              await htmlContentRecoveryService.isAccountGenerationCurrent(context.recovery) else {
            return false
        }
        if let parsedEmail = context.parsedEmail,
           !(await parsedEmailProvider.isAccountGenerationCurrent(parsedEmail)) {
            return false
        }
        return htmlContentHandler.isAccountGenerationCurrent(context.htmlContent) &&
            htmlAnalysisCache.isAccountGenerationCurrent(context.htmlAnalysis)
    }

    private func unavailableContentResult() -> MessageBubbleContentResult {
        MessageBubbleContentResult(
            fullTextContent: nil,
            hasRichHTMLContent: false,
            sharedDocumentLinks: [],
            forwardedDisplayContent: nil,
            htmlAnalysis: .placeholder(hasHTMLSource: false),
            isComplete: false
        )
    }

    func nonEmptyText(_ text: String?) -> String? {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    private func extractSharedDocumentLinks(
        preferredText: String?,
        bodyText: String?,
        snippet: String?
    ) -> [SharedDocumentLink] {
        let candidates = [preferredText, bodyText, snippet]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return SharedDocumentLinkExtractor.extract(from: candidates, maxCount: 4)
    }
}
