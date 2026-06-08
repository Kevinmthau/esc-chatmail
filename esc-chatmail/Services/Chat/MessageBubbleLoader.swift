import CryptoKit
import Foundation

private extension ForwardedMessageDisplayContent {
    var hasForwardedHeaderFields: Bool {
        senderDisplayName != nil ||
        senderEmail != nil ||
        subject != nil ||
        timestampText != nil ||
        recipientSummary != nil
    }

    func replacingLeadInText(with leadInText: String?) -> ForwardedMessageDisplayContent {
        ForwardedMessageDisplayContent(
            leadInText: leadInText,
            senderDisplayName: senderDisplayName,
            senderEmail: senderEmail,
            subject: subject,
            timestampText: timestampText,
            recipientSummary: recipientSummary,
            previewSnippet: previewSnippet
        )
    }

    func supplementingMissingHeaderFields(
        from fallback: ForwardedMessageDisplayContent
    ) -> ForwardedMessageDisplayContent {
        ForwardedMessageDisplayContent(
            leadInText: leadInText,
            senderDisplayName: senderDisplayName ?? fallback.senderDisplayName,
            senderEmail: senderEmail ?? fallback.senderEmail,
            subject: subject ?? fallback.subject,
            timestampText: timestampText ?? fallback.timestampText,
            recipientSummary: recipientSummary ?? fallback.recipientSummary,
            previewSnippet: previewSnippet
        )
    }
}

/// Legacy compatibility for outgoing records created before chatPreviewText was
/// populated from the composed body. Normal outgoing bubbles use the persisted
/// chatPreviewText and do not need this body-vs-loaded-text comparison.
private enum LegacyOutgoingBodyTextFallback {
    static func preferredBodyText(
        _ outgoingBodyText: String?,
        over loadedText: String?
    ) -> String? {
        guard let outgoingBodyText,
              let candidate = comparableText(outgoingBodyText) else {
            return nil
        }

        guard let comparison = comparableText(loadedText) else {
            return outgoingBodyText
        }

        guard isRicher(candidate, than: comparison) else {
            return nil
        }

        return outgoingBodyText
    }

    private static func isRicher(_ candidate: ComparableText, than comparison: ComparableText) -> Bool {
        guard candidate.normalizedText.hasPrefix(comparison.normalizedText) else {
            return false
        }
        return candidate.tokenCount > comparison.tokenCount ||
            candidate.characterCount > comparison.characterCount
    }

    private static func comparableText(_ text: String?) -> ComparableText? {
        guard let text else { return nil }

        let normalizedText = HTMLEntityDecoder.decode(text)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        guard !normalizedText.isEmpty else {
            return nil
        }

        let tokenCount = normalizedText.split(separator: " ").count
        return ComparableText(
            normalizedText: normalizedText,
            tokenCount: tokenCount,
            characterCount: normalizedText.count
        )
    }

    private struct ComparableText {
        let normalizedText: String
        let tokenCount: Int
        let characterCount: Int
    }
}

actor MessageBubbleLoader: MessageBubbleLoading {
    private let contactsResolver: any ContactsResolving
    private let processedTextCache: ProcessedTextCache
    private let htmlContentHandler: HTMLContentHandler
    private let htmlContentLoader: HTMLContentLoader
    private let htmlContentRecoveryService: any HTMLContentRecovering
    private let htmlAnalysisCache: MessageBubbleHTMLAnalysisCache
    private let parsedEmailProvider: any ParsedEmailProviding
    private let renderedMessageCache: RenderedMessageCache

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

    private func forwardedDisplayContent(
        from request: MessageBubbleContentRequest
    ) -> ForwardedMessageDisplayContent? {
        guard request.isForwardedEmail else {
            return nil
        }

        if let chatPreviewText = nonEmptyText(request.chatPreviewText) {
            let fallbackContent = firstForwardedDisplayContent(
                from: [request.bodyText, request.cleanedSnippet, request.snippet]
            )

            guard let chatPreviewContent = ForwardedMessageDisplayParser.parseForward(from: chatPreviewText) else {
                return fallbackContent?.replacingLeadInText(with: chatPreviewText)
            }

            guard !chatPreviewContent.hasForwardedHeaderFields,
                  let fallbackContent else {
                return chatPreviewContent
            }

            return chatPreviewContent.supplementingMissingHeaderFields(from: fallbackContent)
        }

        return firstForwardedDisplayContent(
            from: [request.bodyText, request.cleanedSnippet, request.snippet]
        )
    }

    private func firstForwardedDisplayContent(
        from texts: [String?]
    ) -> ForwardedMessageDisplayContent? {
        for text in texts {
            if let content = ForwardedMessageDisplayParser.parseForward(from: text) {
                return content
            }
        }

        return nil
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

    private func cachedHTMLAnalysis(for request: MessageBubbleContentRequest) async -> MessageBubbleHTMLAnalysis {
        let variantKey = RenderedMessageVariantKey(htmlAnalysisCacheKey(for: request))
        let sourceSignature = renderedSourceSignature(for: request)

        let analysis = await renderedMessageCache.htmlAnalysis(
            messageId: request.messageID,
            sourceSignature: sourceSignature,
            variantKey: variantKey
        ) {
            if let cached = self.htmlAnalysisCache.value(forKey: variantKey.rawValue) {
                return cached
            }

            return await self.buildHTMLAnalysis(for: request)
        } ?? .placeholder(hasHTMLSource: request.hasHTMLSource)

        htmlAnalysisCache.setValue(analysis, forKey: variantKey.rawValue)
        return analysis
    }

    private func buildHTMLAnalysis(for request: MessageBubbleContentRequest) async -> MessageBubbleHTMLAnalysis {
        let canonicalContent = await canonicalContentForAnalysisIfNeeded(for: request)
        let canonicalHTML = canonicalContent?.html
        let parsedEmail: ParsedEmail?
        if let canonicalHTML, let canonicalContent {
            parsedEmail = await parsedEmailProvider.parsedEmail(
                messageId: request.messageID,
                sourceSignature: canonicalContent.sourceSignature,
                canonicalHTML: canonicalHTML
            )
        } else {
            parsedEmail = nil
        }

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: canonicalHTML,
            parsedEmail: parsedEmail,
            hasHTMLSourceHint: request.hasHTMLSource,
            isForwardedEmail: request.isForwardedEmail,
            isLikelyCalendarInvite: request.isLikelyCalendarInvite,
            bodyText: request.bodyText,
            cleanedSnippet: request.cleanedSnippet,
            senderName: request.senderName,
            senderEmail: request.effectiveSenderEmail,
            subject: request.subject,
            attachmentSnapshots: request.attachmentSnapshots
        )
        return analysis
    }

    private func nonEmptyText(_ text: String?) -> String? {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    private func canonicalContentForAnalysisIfNeeded(for request: MessageBubbleContentRequest) async -> CanonicalEmailContent? {
        let needsCanonicalHTML =
            request.hasAttachments ||
            !request.attachmentSnapshots.isEmpty ||
            (!request.isForwardedEmail && request.isLikelyCalendarInvite)
        let shouldResolveMissingHTMLHint =
            !request.hasHTMLSource &&
            (
                request.bodyStorageURI != nil ||
                htmlContentHandler.htmlFileExists(for: request.messageID)
            )

        guard needsCanonicalHTML || shouldResolveMissingHTMLHint else {
            return nil
        }

        guard request.hasHTMLSource ||
                request.bodyStorageURI != nil ||
                htmlContentHandler.htmlFileExists(for: request.messageID) else {
            return nil
        }

        return await htmlContentLoader.loadCanonicalEmailContent(
            messageId: request.messageID,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            allowRecovery: false
        )
    }

    private func htmlAnalysisCacheKey(for request: MessageBubbleContentRequest) -> String {
        let htmlSourceSignature = htmlContentHandler.htmlSourceSignature(
            messageId: request.messageID,
            bodyStorageURI: request.bodyStorageURI
        )
        return [
            request.messageID,
            request.bodyStorageURI ?? "storage:nil",
            "html:\(htmlSourceSignature)",
            "body:\(cacheFingerprint(for: request.bodyText))",
            "snippet:\(cacheFingerprint(for: request.cleanedSnippet))",
            "subject:\(cacheFingerprint(for: request.subject))",
            "sender:\(cacheFingerprint(for: request.senderName))",
            "email:\(cacheFingerprint(for: request.effectiveSenderEmail))",
            "flags:\(request.hasHTMLSource)-\(request.isForwardedEmail)-\(request.isLikelyCalendarInvite)",
            "hasAttachments:\(request.hasAttachments)",
            "attachments:\(attachmentFingerprint(for: request.attachmentSnapshots))"
        ].joined(separator: "|")
    }

    private func renderedSourceSignature(for request: MessageBubbleContentRequest) -> String {
        ProcessedTextCache.contentSourceSignature(
            messageId: request.messageID,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            handler: htmlContentHandler
        )
    }

    private func cacheFingerprint(for text: String?) -> String {
        guard let text = text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            return "nil"
        }

        return SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func attachmentFingerprint(for attachments: [MessageBubbleAttachmentSnapshot]) -> String {
        guard !attachments.isEmpty else { return "none" }

        return attachments
            .map { attachment in
                [
                    EmailDocument.normalizedContentID(attachment.contentId) ?? "cid:nil",
                    attachment.filename.lowercased(),
                    attachment.mimeType.lowercased(),
                    "\(attachment.width)x\(attachment.height)"
                ].joined(separator: "~")
            }
            .joined(separator: ";")
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
