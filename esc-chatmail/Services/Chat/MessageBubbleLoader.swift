import Foundation

actor MessageBubbleLoader: MessageBubbleLoading {
    private let contactsResolver: any ContactsResolving
    private let processedTextCache: ProcessedTextCache
    let htmlContentHandler: HTMLContentHandler
    let htmlContentLoader: HTMLContentLoader
    private let htmlContentRecoveryService: any HTMLContentRecovering
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

    private func loadRichContentClassification(
        from request: MessageBubbleContentRequest,
        resolvedHasHTMLSource: Bool
    ) async -> Bool {
        guard !request.isFromMe else {
            return false
        }

        let sourceSignature = renderedSourceSignature(for: request)
        let variantKey = RenderedMessageVariantKey(ProcessedTextCache.richContentAnalysisMode)

        return await renderedMessageCache.richContentClassification(
            messageId: request.messageID,
            sourceSignature: sourceSignature,
            variantKey: variantKey
        ) {
            if let cached = await self.processedTextCache.get(
                messageId: request.messageID,
                sourceSignature: sourceSignature,
                previewMode: ProcessedTextCache.richContentAnalysisMode
            ) {
                return cached.hasRichContent
            }

            let hasRichContent = ProcessedTextCache.classifyRichContent(
                messageId: request.messageID,
                bodyStorageURI: request.bodyStorageURI,
                bodyText: request.bodyText,
                handler: self.htmlContentHandler
            )
            let resolvedHasRichContent = hasRichContent || (
                resolvedHasHTMLSource &&
                self.looksLikeNewsletterFallbackText(request.bodyText ?? request.snippet)
            )

            await self.processedTextCache.set(
                messageId: request.messageID,
                sourceSignature: sourceSignature,
                previewMode: ProcessedTextCache.richContentAnalysisMode,
                plainText: nil,
                hasRichContent: resolvedHasRichContent
            )

            return resolvedHasRichContent
        } ?? false
    }

    private func loadCompatibilityContent(
        from request: MessageBubbleContentRequest,
        resolvedHasHTMLSource: Bool
    ) async -> (plainText: String?, hasRichContent: Bool) {
        // Compatibility path for old records with missing chatPreviewText.
        // HTML-backed messages derive text through the DOM-backed extractor;
        // true plain-text-only messages use the legacy plain-text cleanup below.
        let sourceSignature = renderedSourceSignature(for: request)
        let chatVariantKey = RenderedMessageVariantKey(ProcessedTextCache.chatBubblePreviewMode)

        var fallbackSourceSignature: String?
        func resolveFallbackSourceSignature() -> String {
            if let fallbackSourceSignature {
                return fallbackSourceSignature
            }

            let signature = ProcessedTextCache.fallbackContentSourceSignature(
                messageId: request.messageID,
                bodyStorageURI: request.bodyStorageURI,
                bodyText: request.bodyText,
                handler: htmlContentHandler
            )
            fallbackSourceSignature = signature
            return signature
        }

        func isStaleNewsletterFallback(plainText: String?, hasRichContent: Bool) -> Bool {
            guard !request.isFromMe,
                  resolvedHasHTMLSource,
                  !hasRichContent else {
                return false
            }

            return looksLikeNewsletterFallbackText(request.bodyText ?? request.snippet) ||
                looksLikeNewsletterFallbackText(plainText)
        }

        if let cached = await renderedMessageCache.cachedChatBubbleText(
            messageId: request.messageID,
            sourceSignature: sourceSignature,
            variantKey: chatVariantKey
        ) {
            let requiresURIRecompute =
                resolvedHasHTMLSource &&
                cached.plainText == nil &&
                request.bodyStorageURI != nil &&
                !htmlContentHandler.htmlFileExists(for: request.messageID)
            let requiresBodyFallbackRecompute =
                cached.plainText == nil &&
                !cached.hasRichContent &&
                resolveFallbackSourceSignature() != sourceSignature
            let shouldBypassCachedNewsletterFallback = isStaleNewsletterFallback(
                plainText: cached.plainText,
                hasRichContent: cached.hasRichContent
            )

            if !requiresURIRecompute && !requiresBodyFallbackRecompute && !shouldBypassCachedNewsletterFallback {
                return (
                    cached.plainText,
                    cached.hasRichContent
                )
            }
        }

        if let cached = await processedTextCache.get(
            messageId: request.messageID,
            sourceSignature: sourceSignature,
            previewMode: ProcessedTextCache.chatBubblePreviewMode
        ) {
            let requiresURIRecompute =
                resolvedHasHTMLSource &&
                cached.plainText == nil &&
                request.bodyStorageURI != nil &&
                !htmlContentHandler.htmlFileExists(for: request.messageID)
            let requiresBodyFallbackRecompute =
                cached.plainText == nil &&
                !cached.hasRichContent &&
                resolveFallbackSourceSignature() != sourceSignature
            let shouldBypassCachedNewsletterFallback = isStaleNewsletterFallback(
                plainText: cached.plainText,
                hasRichContent: cached.hasRichContent
            )

            if !requiresURIRecompute && !requiresBodyFallbackRecompute && !shouldBypassCachedNewsletterFallback {
                await renderedMessageCache.storeChatBubbleText(
                    RenderedMessageChatBubbleText(
                        plainText: cached.plainText,
                        hasRichContent: cached.hasRichContent,
                        quotedParts: cached.quotedParts
                    ),
                    messageId: request.messageID,
                    sourceSignature: sourceSignature,
                    variantKey: chatVariantKey
                )
                return (
                    cached.plainText,
                    cached.hasRichContent
                )
            }
        }

        let resolvedFallbackSourceSignature = resolveFallbackSourceSignature()
        if resolvedFallbackSourceSignature != sourceSignature,
           let cached = await renderedMessageCache.cachedChatBubbleText(
                messageId: request.messageID,
                sourceSignature: resolvedFallbackSourceSignature,
                variantKey: chatVariantKey
           ) {
            let requiresURIRecompute =
                resolvedHasHTMLSource &&
                cached.plainText == nil &&
                request.bodyStorageURI != nil &&
                !htmlContentHandler.htmlFileExists(for: request.messageID)
            let shouldBypassCachedNewsletterFallback = isStaleNewsletterFallback(
                plainText: cached.plainText,
                hasRichContent: cached.hasRichContent
            )

            if !requiresURIRecompute && !shouldBypassCachedNewsletterFallback {
                return (
                    cached.plainText,
                    cached.hasRichContent
                )
            }
        }

        if resolvedFallbackSourceSignature != sourceSignature,
           let cached = await processedTextCache.get(
                messageId: request.messageID,
                sourceSignature: resolvedFallbackSourceSignature,
                previewMode: ProcessedTextCache.chatBubblePreviewMode
           ) {
            let requiresURIRecompute =
                resolvedHasHTMLSource &&
                cached.plainText == nil &&
                request.bodyStorageURI != nil &&
                !htmlContentHandler.htmlFileExists(for: request.messageID)
            let shouldBypassCachedNewsletterFallback = isStaleNewsletterFallback(
                plainText: cached.plainText,
                hasRichContent: cached.hasRichContent
            )

            if !requiresURIRecompute && !shouldBypassCachedNewsletterFallback {
                await renderedMessageCache.storeChatBubbleText(
                    RenderedMessageChatBubbleText(
                        plainText: cached.plainText,
                        hasRichContent: cached.hasRichContent,
                        quotedParts: cached.quotedParts
                    ),
                    messageId: request.messageID,
                    sourceSignature: resolvedFallbackSourceSignature,
                    variantKey: chatVariantKey
                )
                return (
                    cached.plainText,
                    cached.hasRichContent
                )
            }
        }

        var result = await processMessageContent(
            from: request,
            sourceSignature: sourceSignature,
            fallbackSourceSignature: resolvedFallbackSourceSignature
        )

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
            (request.bodyStorageURI != nil || request.hasAttachments || resolvedHasHTMLSource)
        let shouldAttemptTrustedSenderRecovery =
            !request.isFromMe &&
            !resolvedHasHTMLSource &&
            !result.hasRichContent &&
            isTrustedTransactionalSender
        let shouldAttemptNewsletterFallbackRecovery =
            !request.isFromMe &&
            resolvedHasHTMLSource &&
            !result.hasRichContent &&
            looksLikeNewsletterFallbackText(request.bodyText ?? result.plainText ?? request.snippet)

        if (shouldAttemptHTMLRecovery || shouldAttemptTrustedSenderRecovery || shouldAttemptNewsletterFallbackRecovery),
           let recoveredHTML = await htmlContentRecoveryService.recoverHTMLContent(messageId: request.messageID) {
            let recoveredResult = ChatBubbleTextProcessor.htmlCompatibilityFallback(
                from: recoveredHTML,
                classifyRichContent: true
            )
            let recoveredHasRichContent =
                recoveredResult.hasRichContent || shouldAttemptNewsletterFallbackRecovery

            await processedTextCache.set(
                messageId: request.messageID,
                sourceSignature: sourceSignature,
                previewMode: ProcessedTextCache.chatBubblePreviewMode,
                plainText: recoveredResult.mainText,
                hasRichContent: recoveredHasRichContent,
                quotedParts: recoveredResult.quotedParts
            )
            await renderedMessageCache.storeChatBubbleText(
                RenderedMessageChatBubbleText(
                    plainText: recoveredResult.mainText,
                    hasRichContent: recoveredHasRichContent,
                    quotedParts: recoveredResult.quotedParts
                ),
                messageId: request.messageID,
                sourceSignature: sourceSignature,
                variantKey: chatVariantKey
            )

            if recoveredResult.mainText != nil || recoveredHasRichContent {
                result = (
                    plainText: recoveredResult.mainText,
                    hasRichContent: recoveredHasRichContent
                )
            }
        }

        return result
    }

    nonisolated private func looksLikeNewsletterFallbackText(_ text: String?) -> Bool {
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
        from request: MessageBubbleContentRequest,
        sourceSignature: String,
        fallbackSourceSignature: String
    ) async -> (plainText: String?, hasRichContent: Bool) {
        var processedResult = ProcessedTextCache.processMessage(
            messageId: request.messageID,
            bodyStorageURI: request.bodyStorageURI,
            handler: htmlContentHandler
        )
        var cacheSourceSignature = sourceSignature

        if processedResult.plainText == nil, let text = request.bodyText {
            let fallbackContent = RawEmailSourceSanitizer.extractHTMLText(from: text) ?? text
            let fallbackInputKind: ChatBubbleTextInputKind =
                fallbackContent == text ? .autoDetectHTML : .html
            let fallbackResult: ChatBubbleTextProcessingResult
            if fallbackInputKind == .html {
                fallbackResult = ChatBubbleTextProcessor.htmlCompatibilityFallback(
                    from: fallbackContent,
                    classifyRichContent: true
                )
            } else {
                fallbackResult = ChatBubbleTextProcessor.legacyAutoDetectedFallback(
                    from: fallbackContent,
                    sanitizeRawEmailSource: true,
                    classifyRichContent: true
                )
            }
            processedResult = (
                fallbackResult.mainText,
                fallbackResult.hasRichContent,
                fallbackResult.quotedParts
            )
            cacheSourceSignature = fallbackSourceSignature
        }

        await processedTextCache.set(
            messageId: request.messageID,
            sourceSignature: cacheSourceSignature,
            previewMode: ProcessedTextCache.chatBubblePreviewMode,
            plainText: processedResult.plainText,
            hasRichContent: processedResult.hasRichContent,
            quotedParts: processedResult.quotedParts
        )
        await renderedMessageCache.storeChatBubbleText(
            RenderedMessageChatBubbleText(
                plainText: processedResult.plainText,
                hasRichContent: processedResult.hasRichContent,
                quotedParts: processedResult.quotedParts
            ),
            messageId: request.messageID,
            sourceSignature: cacheSourceSignature,
            variantKey: RenderedMessageVariantKey(ProcessedTextCache.chatBubblePreviewMode)
        )

        return (
            plainText: processedResult.plainText,
            hasRichContent: processedResult.hasRichContent
        )
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
