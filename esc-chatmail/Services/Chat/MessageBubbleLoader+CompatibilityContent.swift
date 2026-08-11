import Foundation

extension MessageBubbleLoader {
    func loadRichContentClassification(
        from request: MessageBubbleContentRequest,
        resolvedHasHTMLSource: Bool,
        accountContext: MessageBubbleAccountWorkContext
    ) async -> Bool {
        guard !request.isFromMe,
              await isAccountWorkContextCurrent(accountContext) else {
            return false
        }

        let sourceSignature = renderedSourceSignature(
            for: request,
            accountContext: accountContext
        )
        let variantKey = RenderedMessageVariantKey(ProcessedTextCache.richContentAnalysisMode)

        return await renderedMessageCache.richContentClassification(
            messageId: request.messageID,
            sourceSignature: sourceSignature,
            variantKey: variantKey,
            expectedAccountGeneration: accountContext.renderedMessage
        ) {
            if let cached = await self.processedTextCache.get(
                messageId: request.messageID,
                sourceSignature: sourceSignature,
                previewMode: ProcessedTextCache.richContentAnalysisMode,
                expectedAccountGeneration: accountContext.processedText
            ) {
                return cached.hasRichContent
            }

            let hasRichContent = ProcessedTextCache.classifyRichContent(
                messageId: request.messageID,
                bodyStorageURI: request.bodyStorageURI,
                bodyText: request.bodyText,
                handler: self.htmlContentHandler,
                expectedAccountGeneration: accountContext.htmlContent
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
                hasRichContent: resolvedHasRichContent,
                expectedAccountGeneration: accountContext.processedText
            )

            return resolvedHasRichContent
        } ?? false
    }

    func loadCompatibilityContent(
        from request: MessageBubbleContentRequest,
        resolvedHasHTMLSource: Bool,
        accountContext: MessageBubbleAccountWorkContext
    ) async -> (plainText: String?, hasRichContent: Bool) {
        guard await isAccountWorkContextCurrent(accountContext) else {
            return (nil, false)
        }
        // Compatibility path for old records with missing chatPreviewText.
        // HTML-backed messages derive text through the DOM-backed extractor;
        // true plain-text-only messages use the legacy plain-text cleanup below.
        let sourceSignature = renderedSourceSignature(
            for: request,
            accountContext: accountContext
        )
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
                handler: htmlContentHandler,
                expectedAccountGeneration: accountContext.htmlContent
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
            variantKey: chatVariantKey,
            expectedAccountGeneration: accountContext.renderedMessage
        ) {
            let requiresURIRecompute =
                resolvedHasHTMLSource &&
                cached.plainText == nil &&
                request.bodyStorageURI != nil &&
                !htmlContentHandler.htmlFileExists(
                    for: request.messageID,
                    expectedGeneration: accountContext.htmlContent
                )
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
            previewMode: ProcessedTextCache.chatBubblePreviewMode,
            expectedAccountGeneration: accountContext.processedText
        ) {
            let requiresURIRecompute =
                resolvedHasHTMLSource &&
                cached.plainText == nil &&
                request.bodyStorageURI != nil &&
                !htmlContentHandler.htmlFileExists(
                    for: request.messageID,
                    expectedGeneration: accountContext.htmlContent
                )
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
                    variantKey: chatVariantKey,
                    expectedAccountGeneration: accountContext.renderedMessage
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
               variantKey: chatVariantKey,
               expectedAccountGeneration: accountContext.renderedMessage
           ) {
            let requiresURIRecompute =
                resolvedHasHTMLSource &&
                cached.plainText == nil &&
                request.bodyStorageURI != nil &&
                !htmlContentHandler.htmlFileExists(
                    for: request.messageID,
                    expectedGeneration: accountContext.htmlContent
                )
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
               previewMode: ProcessedTextCache.chatBubblePreviewMode,
               expectedAccountGeneration: accountContext.processedText
           ) {
            let requiresURIRecompute =
                resolvedHasHTMLSource &&
                cached.plainText == nil &&
                request.bodyStorageURI != nil &&
                !htmlContentHandler.htmlFileExists(
                    for: request.messageID,
                    expectedGeneration: accountContext.htmlContent
                )
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
                    variantKey: chatVariantKey,
                    expectedAccountGeneration: accountContext.renderedMessage
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
            fallbackSourceSignature: resolvedFallbackSourceSignature,
            accountContext: accountContext
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
           await isAccountWorkContextCurrent(accountContext),
           let recoveredHTML = await htmlContentRecoveryService.recoverHTMLContent(
               messageId: request.messageID,
               expectedAccountGeneration: accountContext.recovery
           ) {
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
                quotedParts: recoveredResult.quotedParts,
                expectedAccountGeneration: accountContext.processedText
            )
            await renderedMessageCache.storeChatBubbleText(
                RenderedMessageChatBubbleText(
                    plainText: recoveredResult.mainText,
                    hasRichContent: recoveredHasRichContent,
                    quotedParts: recoveredResult.quotedParts
                ),
                messageId: request.messageID,
                sourceSignature: sourceSignature,
                variantKey: chatVariantKey,
                expectedAccountGeneration: accountContext.renderedMessage
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
        fallbackSourceSignature: String,
        accountContext: MessageBubbleAccountWorkContext
    ) async -> (plainText: String?, hasRichContent: Bool) {
        var processedResult = ProcessedTextCache.processMessage(
            messageId: request.messageID,
            bodyStorageURI: request.bodyStorageURI,
            handler: htmlContentHandler,
            expectedAccountGeneration: accountContext.htmlContent
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
            quotedParts: processedResult.quotedParts,
            expectedAccountGeneration: accountContext.processedText
        )
        await renderedMessageCache.storeChatBubbleText(
            RenderedMessageChatBubbleText(
                plainText: processedResult.plainText,
                hasRichContent: processedResult.hasRichContent,
                quotedParts: processedResult.quotedParts
            ),
            messageId: request.messageID,
            sourceSignature: cacheSourceSignature,
            variantKey: RenderedMessageVariantKey(ProcessedTextCache.chatBubblePreviewMode),
            expectedAccountGeneration: accountContext.renderedMessage
        )

        return (
            plainText: processedResult.plainText,
            hasRichContent: processedResult.hasRichContent
        )
    }
}
