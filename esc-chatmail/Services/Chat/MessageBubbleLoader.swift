import Foundation

struct MessageBubbleSenderRequest: Sendable {
    let email: String
    let personDisplayName: String?
    let personAvatarURL: String?
}

struct MessageBubbleSenderResult: Sendable, Equatable {
    let name: String?
    let avatarURL: String?
    let imageData: Data?
}

struct MessageBubbleContentRequest: Sendable {
    let messageID: String
    let bodyText: String?
    let bodyStorageURI: String?
    let snippet: String?
    let hasHTMLSource: Bool
    let hasAttachments: Bool
    let isFromMe: Bool
    let effectiveSenderEmail: String?
}

struct MessageBubbleContentResult: Sendable, Equatable {
    let fullTextContent: String?
    let hasRichHTMLContent: Bool
    let sharedDocumentLinks: [SharedDocumentLink]
}

struct MessageBubbleLoadContext: Sendable {
    let messageID: String
    let contentSignature: String
    let prefetchedSenderName: String?
    let senderRequest: MessageBubbleSenderRequest?
    let contentRequest: MessageBubbleContentRequest
}

protocol MessageBubbleLoading: Sendable {
    func loadSenderInfo(from request: MessageBubbleSenderRequest) async -> MessageBubbleSenderResult
    func loadContent(from request: MessageBubbleContentRequest) async -> MessageBubbleContentResult
}

actor MessageBubbleLoader: MessageBubbleLoading {
    private let contactsResolver: any ContactsResolving
    private let processedTextCache: ProcessedTextCache
    private let htmlContentHandler: HTMLContentHandler
    private let htmlContentRecoveryService: any HTMLContentRecovering

    init(
        contactsResolver: any ContactsResolving = ContactsResolver.shared,
        processedTextCache: ProcessedTextCache = .shared,
        htmlContentHandler: HTMLContentHandler = .shared,
        htmlContentRecoveryService: any HTMLContentRecovering = HTMLContentRecoveryService.shared
    ) {
        self.contactsResolver = contactsResolver
        self.processedTextCache = processedTextCache
        self.htmlContentHandler = htmlContentHandler
        self.htmlContentRecoveryService = htmlContentRecoveryService
    }

    func loadSenderInfo(from request: MessageBubbleSenderRequest) async -> MessageBubbleSenderResult {
        let match = await contactsResolver.lookup(email: request.email)
        let preferredName = request.personDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedName: String
        if let preferredName, !preferredName.isEmpty {
            resolvedName = preferredName
        } else if let displayName = match?.displayName, !displayName.isEmpty {
            resolvedName = displayName
        } else {
            resolvedName = EmailNormalizer.formatAsDisplayName(email: request.email)
        }

        return MessageBubbleSenderResult(
            name: resolvedName,
            avatarURL: request.personAvatarURL,
            imageData: match?.imageData
        )
    }

    func loadContent(from request: MessageBubbleContentRequest) async -> MessageBubbleContentResult {
        let loadedContent = await loadProcessedContent(from: request)
        return MessageBubbleContentResult(
            fullTextContent: loadedContent.plainText,
            hasRichHTMLContent: loadedContent.hasRichContent,
            sharedDocumentLinks: extractSharedDocumentLinks(
                preferredText: loadedContent.plainText,
                bodyText: request.bodyText,
                snippet: request.snippet
            )
        )
    }

    private func loadProcessedContent(
        from request: MessageBubbleContentRequest
    ) async -> (plainText: String?, hasRichContent: Bool) {
        if let cached = await processedTextCache.get(messageId: request.messageID) {
            let hasHTMLFile = htmlContentHandler.htmlFileExists(for: request.messageID)
            let requiresURIRecompute =
                request.hasHTMLSource &&
                cached.plainText == nil &&
                request.bodyStorageURI != nil &&
                !hasHTMLFile

            if !requiresURIRecompute {
                return (cached.plainText, cached.hasRichContent)
            }
        }

        var result = await processMessageContent(from: request)

        let missingBodyText = request.bodyText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true
        let isTrustedTransactionalSender = MessageDisplayPolicy.isTrustedTransactionalSender(
            request.effectiveSenderEmail
        )
        let shouldAttemptHTMLRecovery =
            result.plainText == nil &&
            missingBodyText &&
            !request.isFromMe &&
            (request.bodyStorageURI != nil || request.hasAttachments || request.hasHTMLSource)
        let shouldAttemptTrustedSenderRecovery =
            !request.isFromMe &&
            !request.hasHTMLSource &&
            !result.hasRichContent &&
            isTrustedTransactionalSender

        if (shouldAttemptHTMLRecovery || shouldAttemptTrustedSenderRecovery),
           let recoveredHTML = await htmlContentRecoveryService.recoverHTMLContent(messageId: request.messageID) {
            let recoveredResult = ChatBubbleTextProcessor.process(
                content: recoveredHTML,
                options: ChatBubbleTextProcessorOptions(
                    inputKind: .html,
                    sanitizeRawEmailSource: false,
                    decodeHTMLEntities: true,
                    formatSignOffLineBreaks: true,
                    classifyRichContent: true
                )
            )

            await processedTextCache.set(
                messageId: request.messageID,
                plainText: recoveredResult.mainText,
                hasRichContent: recoveredResult.hasRichContent,
                quotedParts: recoveredResult.quotedParts
            )

            if recoveredResult.mainText != nil || recoveredResult.hasRichContent {
                result = (recoveredResult.mainText, recoveredResult.hasRichContent)
            }
        }

        return result
    }

    private func processMessageContent(
        from request: MessageBubbleContentRequest
    ) async -> (plainText: String?, hasRichContent: Bool) {
        var processedResult = ProcessedTextCache.processMessage(
            messageId: request.messageID,
            bodyStorageURI: request.bodyStorageURI,
            handler: htmlContentHandler
        )

        if processedResult.plainText == nil, let text = request.bodyText {
            let fallbackResult = ChatBubbleTextProcessor.process(
                content: text,
                options: ChatBubbleTextProcessorOptions(
                    inputKind: .autoDetectHTML,
                    sanitizeRawEmailSource: true,
                    decodeHTMLEntities: true,
                    formatSignOffLineBreaks: true,
                    classifyRichContent: true
                )
            )
            processedResult = (
                fallbackResult.mainText,
                fallbackResult.hasRichContent,
                fallbackResult.quotedParts
            )
        }

        await processedTextCache.set(
            messageId: request.messageID,
            plainText: processedResult.plainText,
            hasRichContent: processedResult.hasRichContent,
            quotedParts: processedResult.quotedParts
        )

        return (processedResult.plainText, processedResult.hasRichContent)
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
