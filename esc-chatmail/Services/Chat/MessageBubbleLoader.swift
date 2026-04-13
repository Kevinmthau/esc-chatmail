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
    let isForwardedEmail: Bool
    let effectiveSenderEmail: String?
}

struct MessageBubbleContentResult: Sendable, Equatable {
    let fullTextContent: String?
    let hasRichHTMLContent: Bool
    let sharedDocumentLinks: [SharedDocumentLink]
    let forwardedDisplayContent: ForwardedMessageDisplayContent?
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
        let contactName = match?.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedName: String
        if let contactName, !contactName.isEmpty {
            resolvedName = contactName
        } else if let preferredName, !preferredName.isEmpty {
            resolvedName = preferredName
        } else {
            resolvedName = EmailNormalizer.formatAsDisplayName(email: request.email)
        }

        let resolvedAvatarURL: String? = match == nil ? request.personAvatarURL : nil

        return MessageBubbleSenderResult(
            name: resolvedName,
            avatarURL: resolvedAvatarURL,
            imageData: match?.imageData
        )
    }

    func loadContent(from request: MessageBubbleContentRequest) async -> MessageBubbleContentResult {
        let forwardedDisplayContent =
            request.isFromMe && request.isForwardedEmail
            ? ForwardedMessageDisplayParser.parseOutgoingForward(
                from: request.bodyText ?? request.snippet
            )
            : nil
        let loadedContent = await loadProcessedContent(from: request)

        let fullTextContent =
            forwardedDisplayContent != nil
            ? forwardedDisplayContent?.leadInText
            : loadedContent.plainText
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
            forwardedDisplayContent: forwardedDisplayContent
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
            let shouldBypassCachedNewsletterFallback =
                !request.isFromMe &&
                request.hasHTMLSource &&
                !cached.hasRichContent &&
                looksLikeNewsletterFallbackText(cached.plainText ?? request.bodyText ?? request.snippet)

            if !requiresURIRecompute && !shouldBypassCachedNewsletterFallback {
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
        let shouldAttemptNewsletterFallbackRecovery =
            !request.isFromMe &&
            request.hasHTMLSource &&
            !result.hasRichContent &&
            looksLikeNewsletterFallbackText(request.bodyText ?? result.plainText ?? request.snippet)

        if (shouldAttemptHTMLRecovery || shouldAttemptTrustedSenderRecovery || shouldAttemptNewsletterFallbackRecovery),
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
            let recoveredHasRichContent =
                recoveredResult.hasRichContent || shouldAttemptNewsletterFallbackRecovery

            await processedTextCache.set(
                messageId: request.messageID,
                plainText: recoveredResult.mainText,
                hasRichContent: recoveredHasRichContent,
                quotedParts: recoveredResult.quotedParts
            )

            if recoveredResult.mainText != nil || recoveredHasRichContent {
                result = (recoveredResult.mainText, recoveredHasRichContent)
            }
        }

        return result
    }

    private func looksLikeNewsletterFallbackText(_ text: String?) -> Bool {
        guard let text = text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            return false
        }

        let lowercased = text.lowercased()
        let hasNewsletterMarkers =
            lowercased.contains("view in browser") ||
            lowercased.contains("unsubscribe") ||
            lowercased.contains("manage subscriptions") ||
            lowercased.contains("manage preferences") ||
            lowercased.contains("privacy policy")

        guard hasNewsletterMarkers else {
            return false
        }

        let urlLikeCount = text.components(separatedBy: .newlines).reduce(into: 0) { count, line in
            let lowerLine = line.lowercased()
            if lowerLine.contains("http://") || lowerLine.contains("https://") {
                count += 1
            }
        }

        return urlLikeCount >= 2
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
            let fallbackContent = RawEmailSourceSanitizer.extractHTMLText(from: text) ?? text
            let fallbackInputKind: ChatBubbleTextInputKind =
                fallbackContent == text ? .autoDetectHTML : .html
            let shouldSanitizeRawSource: Bool
            switch fallbackInputKind {
            case .html:
                shouldSanitizeRawSource = false
            case .plainText, .autoDetectHTML:
                shouldSanitizeRawSource = true
            }
            let fallbackResult = ChatBubbleTextProcessor.process(
                content: fallbackContent,
                options: ChatBubbleTextProcessorOptions(
                    inputKind: fallbackInputKind,
                    sanitizeRawEmailSource: shouldSanitizeRawSource,
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
