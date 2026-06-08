import Foundation

actor MessageBubbleLoader: MessageBubbleLoading {
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
        let htmlAnalysis = await cachedHTMLAnalysis(for: request)
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
                    resolvedHasHTMLSource: htmlAnalysis.hasHTMLSource
                )
            )
        } else {
            loadedContent = await loadCompatibilityContent(
                from: request,
                resolvedHasHTMLSource: htmlAnalysis.hasHTMLSource
            )
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
