import Foundation

extension MessageBubbleLoader {
    /// The verdict `RichContentVerdictResolver` gives the request's stored state, or nil when
    /// it cannot be determined: the account context went stale, or an HTML file exists but
    /// could not be read.
    ///
    /// The same rule sync, the launch backfill and the refresher persist on the row
    /// (`Message.richContentVerdict`), evaluated over the same inputs, so a stored verdict
    /// and this load can only disagree when the stored one is stale. It takes no
    /// has-HTML-source argument from the HTML analysis for that reason: the resolver derives
    /// that term from stored state, as the writers must.
    ///
    /// Only the classifier term is memoized, under the candidate's source signature, which
    /// is all that key covers. Own rows and the fallback-text term are decided fresh on
    /// every call; memoized with the classifier they outlived a changed snippet, body or
    /// storage URI.
    func loadRichContentClassification(
        from request: MessageBubbleContentRequest,
        accountContext: MessageBubbleAccountWorkContext
    ) async -> Bool? {
        guard !request.isFromMe else { return false }
        guard await isAccountWorkContextCurrent(accountContext) else { return nil }

        let inputs = request.richContentVerdictInputs
        let handler = htmlContentHandler
        let generation = accountContext.htmlContent
        switch RichContentVerdictResolver.cheapTerms(
            for: inputs,
            storedHTML: .readThroughHandler,
            handler: handler,
            generation: generation
        ) {
        case .decided(let isRich):
            return isRich
        case .classifierDecides:
            break
        }

        @Sendable func classifyCandidate() -> Bool? {
            switch RichContentVerdictResolver.classifierCandidate(
                for: inputs,
                storedHTML: .readThroughHandler,
                handler: handler,
                generation: generation
            ) {
            case .html(let html):
                return RichContentClassifier.hasGenuineRichContentAfterCleanup(html)
            case .none:
                return false
            case .undetermined:
                return nil
            }
        }

        // Signature first, candidate second, as before: a file replaced in between then
        // memoizes the new HTML's answer under the old key, which is never asked for again.
        let sourceSignature = renderedSourceSignature(
            for: request,
            accountContext: accountContext
        )
        let variantKey = RenderedMessageVariantKey(MessageBubbleContentSource.richContentAnalysisMode)
        if let memoized = await renderedMessageCache.richContentClassification(
            messageId: request.messageID,
            sourceSignature: sourceSignature,
            variantKey: variantKey,
            expectedAccountGeneration: accountContext.renderedMessage,
            producer: { classifyCandidate() }
        ) {
            return memoized
        }

        // The memo also answers nil when its producer was invalidated mid-flight: an
        // `invalidateContent` for this message (sync, either HTML save site) or a memory
        // warning. That is "nothing memoized", not "not rich". Publishing it as false
        // showed a rich row as text until its signature next changed, and with a stored
        // verdict on screen it would flip a correctly mounted card to text. Evaluate
        // directly instead.
        guard !Task.isCancelled, await isAccountWorkContextCurrent(accountContext) else { return nil }
        return classifyCandidate()
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
        let chatVariantKey = RenderedMessageVariantKey(MessageBubbleContentSource.chatBubblePreviewMode)

        var fallbackSourceSignature: String?
        func resolveFallbackSourceSignature() -> String {
            if let fallbackSourceSignature {
                return fallbackSourceSignature
            }

            let signature = MessageBubbleContentSource.fallbackContentSourceSignature(
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

            return NewsletterFallbackText.looksLikeFallbackText(request.bodyText ?? request.snippet) ||
                NewsletterFallbackText.looksLikeFallbackText(plainText)
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
            NewsletterFallbackText.looksLikeFallbackText(request.bodyText ?? result.plainText ?? request.snippet)

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

    private func processMessageContent(
        from request: MessageBubbleContentRequest,
        sourceSignature: String,
        fallbackSourceSignature: String,
        accountContext: MessageBubbleAccountWorkContext
    ) async -> (plainText: String?, hasRichContent: Bool) {
        var processedResult = MessageBubbleContentSource.processMessage(
            messageId: request.messageID,
            bodyStorageURI: request.bodyStorageURI,
            handler: htmlContentHandler,
            expectedAccountGeneration: accountContext.htmlContent
        )
        var cacheSourceSignature = sourceSignature

        if processedResult.plainText == nil, let text = request.bodyText {
            let fallbackResult = MessageBubbleContentSource.bodyTextFallback(from: text)
            processedResult = (
                fallbackResult.mainText,
                fallbackResult.hasRichContent,
                fallbackResult.quotedParts
            )
            cacheSourceSignature = fallbackSourceSignature
        }

        await renderedMessageCache.storeChatBubbleText(
            RenderedMessageChatBubbleText(
                plainText: processedResult.plainText,
                hasRichContent: processedResult.hasRichContent,
                quotedParts: processedResult.quotedParts
            ),
            messageId: request.messageID,
            sourceSignature: cacheSourceSignature,
            variantKey: RenderedMessageVariantKey(MessageBubbleContentSource.chatBubblePreviewMode),
            expectedAccountGeneration: accountContext.renderedMessage
        )

        return (
            plainText: processedResult.plainText,
            hasRichContent: processedResult.hasRichContent
        )
    }
}
