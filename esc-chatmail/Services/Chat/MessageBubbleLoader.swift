import Foundation

struct MessageBubbleAccountWorkContext: Sendable {
    let htmlContent: HTMLContentAccountGeneration
    let htmlAnalysis: MessageBubbleHTMLAnalysisAccountGeneration
    let parsedEmail: ParsedEmailAccountGeneration?
    let processedText: ProcessedTextCacheAccountGeneration
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
    let processedTextCache: ProcessedTextCache
    let htmlContentHandler: HTMLContentHandler
    let htmlContentLoader: HTMLContentLoader
    let htmlContentRecoveryService: any HTMLContentRecovering
    let htmlAnalysisCache: MessageBubbleHTMLAnalysisCache
    let parsedEmailProvider: any ParsedEmailProviding
    let renderedMessageCache: RenderedMessageCache

    init(
        contactsResolver: any ContactsResolving = ContactsResolver.shared,
        processedTextCache: ProcessedTextCache = .shared,
        htmlContentHandler: HTMLContentHandler = .shared,
        htmlContentLoader: HTMLContentLoader = .shared,
        htmlContentRecoveryService: any HTMLContentRecovering = HTMLContentRecoveryService.shared,
        htmlAnalysisCache: MessageBubbleHTMLAnalysisCache = .shared,
        parsedEmailProvider: any ParsedEmailProviding = ParsedEmailProvider.shared,
        renderedMessageCache: RenderedMessageCache = .shared
    ) {
        self.contactsResolver = contactsResolver
        self.processedTextCache = processedTextCache
        self.htmlContentHandler = htmlContentHandler
        self.htmlContentLoader = htmlContentLoader
        self.htmlContentRecoveryService = htmlContentRecoveryService
        self.htmlAnalysisCache = htmlAnalysisCache
        self.parsedEmailProvider = parsedEmailProvider
        self.renderedMessageCache = renderedMessageCache
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
        let htmlAnalysis = await cachedHTMLAnalysis(for: request, accountContext: accountContext)
        guard await isAccountWorkContextCurrent(accountContext) else {
            return unavailableContentResult()
        }
        let forwardedDisplayContent = forwardedDisplayContent(from: request)
        let storedChatPreviewText = nonEmptyText(request.chatPreviewText)
        let loadedContent: (plainText: String?, hasRichContent: Bool)
        if forwardedDisplayContent != nil {
            loadedContent = (plainText: nil, hasRichContent: false)
        } else if storedChatPreviewText != nil {
            loadedContent = (
                plainText: nil,
                hasRichContent: await loadRichContentClassification(
                    from: request,
                    resolvedHasHTMLSource: htmlAnalysis.hasHTMLSource,
                    accountContext: accountContext
                )
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

        let fullTextContent: String?
        if let forwardedDisplayContent {
            fullTextContent = forwardedDisplayContent.leadInText
        } else if let storedChatPreviewText {
            fullTextContent = storedChatPreviewText
        } else {
            let outgoingBodyFallback = outgoingPlainTextContent(
                from: request,
                loadedPlainText: loadedContent.plainText
            )
            fullTextContent = outgoingBodyFallback ?? loadedContent.plainText
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
              let processedText = await processedTextCache.captureAccountGeneration(),
              let renderedMessage = await renderedMessageCache.captureAccountGeneration(),
              let recovery = await htmlContentRecoveryService.captureAccountGeneration() else {
            return nil
        }
        let parsedEmail = await parsedEmailProvider.captureAccountGeneration()

        let context = MessageBubbleAccountWorkContext(
            htmlContent: htmlContent,
            htmlAnalysis: htmlAnalysis,
            parsedEmail: parsedEmail,
            processedText: processedText,
            renderedMessage: renderedMessage,
            recovery: recovery
        )
        return await isAccountWorkContextCurrent(context) ? context : nil
    }

    func isAccountWorkContextCurrent(_ context: MessageBubbleAccountWorkContext) async -> Bool {
        guard htmlContentHandler.isAccountGenerationCurrent(context.htmlContent),
              htmlAnalysisCache.isAccountGenerationCurrent(context.htmlAnalysis),
              await processedTextCache.isAccountGenerationCurrent(context.processedText),
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
            htmlAnalysis: .placeholder(hasHTMLSource: false)
        )
    }

    private func outgoingPlainTextContent(
        from request: MessageBubbleContentRequest,
        loadedPlainText: String?
    ) -> String? {
        guard request.isFromMe, !request.isForwardedEmail else {
            return nil
        }

        let result = ChatBubbleTextProcessor.legacyAutoDetectedFallback(
            from: request.bodyText,
            sanitizeRawEmailSource: true,
            classifyRichContent: false
        )
        return LegacyOutgoingBodyTextFallback.preferredBodyText(
            result.mainText,
            over: loadedPlainText
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
