import CryptoKit
import Foundation

extension MessageBubbleLoader {
    func loadHTMLAnalysis(
        for request: MessageBubbleContentRequest,
        accountContext: MessageBubbleAccountWorkContext
    ) async -> MessageBubbleHTMLAnalysis? {
        // Recover inside the row's existing task: an unchanged signature won't start another.
        // Pin all attempts to the original account context so retries can't revive old-account work.
        for _ in 0..<3 {
            guard !Task.isCancelled, await isAccountWorkContextCurrent(accountContext) else {
                return nil
            }
            if let analysis = await cachedHTMLAnalysis(for: request, accountContext: accountContext) {
                return analysis
            }
        }
        return nil
    }

    func cachedHTMLAnalysis(
        for request: MessageBubbleContentRequest,
        accountContext: MessageBubbleAccountWorkContext
    ) async -> MessageBubbleHTMLAnalysis? {
        guard await isAccountWorkContextCurrent(accountContext) else {
            return nil
        }
        let variantKey = RenderedMessageVariantKey(htmlAnalysisCacheKey(
            for: request,
            accountContext: accountContext
        ))
        let sourceSignature = renderedSourceSignature(
            for: request,
            accountContext: accountContext
        )

        let analysis = await renderedMessageCache.htmlAnalysis(
            messageId: request.messageID,
            sourceSignature: sourceSignature,
            variantKey: variantKey,
            expectedAccountGeneration: accountContext.renderedMessage
        ) {
            if let cached = self.htmlAnalysisCache.value(
                forKey: variantKey.rawValue,
                expectedGeneration: accountContext.htmlAnalysis
            ) {
                return cached
            }

            return await self.buildHTMLAnalysis(
                for: request,
                accountContext: accountContext
            )
        }

        // An invalidated producer is transient; never memoize its placeholder.
        guard let analysis, await isAccountWorkContextCurrent(accountContext) else {
            return nil
        }

        htmlAnalysisCache.setValue(
            analysis,
            forKey: variantKey.rawValue,
            expectedGeneration: accountContext.htmlAnalysis
        )
        return analysis
    }

    private func buildHTMLAnalysis(
        for request: MessageBubbleContentRequest,
        accountContext: MessageBubbleAccountWorkContext
    ) async -> MessageBubbleHTMLAnalysis {
        let fallback = MessageBubbleHTMLAnalysis.placeholder(hasHTMLSource: request.hasHTMLSource)
        guard await isAccountWorkContextCurrent(accountContext) else { return fallback }
        let canonicalContent = await canonicalContentForAnalysisIfNeeded(
            for: request,
            accountContext: accountContext
        )
        guard await isAccountWorkContextCurrent(accountContext) else { return fallback }
        let canonicalHTML = canonicalContent?.html
        let parsedEmail: ParsedEmail?
        if let canonicalHTML, let canonicalContent {
            parsedEmail = await parsedEmailProvider.parsedEmail(
                messageId: request.messageID,
                sourceSignature: canonicalContent.sourceSignature,
                canonicalHTML: canonicalHTML,
                expectedAccountGeneration: accountContext.parsedEmail
            )
        } else {
            parsedEmail = nil
        }

        guard await isAccountWorkContextCurrent(accountContext) else { return fallback }

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

    private func canonicalContentForAnalysisIfNeeded(
        for request: MessageBubbleContentRequest,
        accountContext: MessageBubbleAccountWorkContext
    ) async -> CanonicalEmailContent? {
        let needsCanonicalHTML =
            request.hasAttachments ||
            !request.attachmentSnapshots.isEmpty ||
            (!request.isForwardedEmail && request.isLikelyCalendarInvite)
        let shouldResolveMissingHTMLHint =
            !request.hasHTMLSource &&
            (
                request.bodyStorageURI != nil ||
                htmlContentHandler.htmlFileExists(
                    for: request.messageID,
                    expectedGeneration: accountContext.htmlContent
                )
            )

        guard needsCanonicalHTML || shouldResolveMissingHTMLHint else {
            return nil
        }

        guard request.hasHTMLSource ||
                request.bodyStorageURI != nil ||
                htmlContentHandler.htmlFileExists(
                    for: request.messageID,
                    expectedGeneration: accountContext.htmlContent
                ) else {
            return nil
        }

        return await htmlContentLoader.loadCanonicalEmailContent(
            messageId: request.messageID,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            allowRecovery: false,
            expectedAccountGeneration: accountContext.htmlContent
        )
    }

    private func htmlAnalysisCacheKey(
        for request: MessageBubbleContentRequest,
        accountContext: MessageBubbleAccountWorkContext
    ) -> String {
        let htmlSourceSignature = htmlContentHandler.htmlSourceSignature(
            messageId: request.messageID,
            bodyStorageURI: request.bodyStorageURI,
            expectedGeneration: accountContext.htmlContent
        )
        // Sender identity is deliberately absent: the analysis output does not
        // depend on it (calendar-card eligibility is sender-independent).
        return [
            request.messageID,
            request.bodyStorageURI ?? "storage:nil",
            "html:\(htmlSourceSignature)",
            "body:\(cacheFingerprint(for: request.bodyText))",
            "snippet:\(cacheFingerprint(for: request.cleanedSnippet))",
            "subject:\(cacheFingerprint(for: request.subject))",
            "flags:\(request.hasHTMLSource)-\(request.isForwardedEmail)-\(request.isLikelyCalendarInvite)",
            "hasAttachments:\(request.hasAttachments)",
            "attachments:\(MessageBubbleAttachmentSnapshot.analysisFingerprint(for: request.attachmentSnapshots))"
        ].joined(separator: "|")
    }

    func renderedSourceSignature(
        for request: MessageBubbleContentRequest,
        accountContext: MessageBubbleAccountWorkContext? = nil
    ) -> String {
        ProcessedTextCache.contentSourceSignature(
            messageId: request.messageID,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            handler: htmlContentHandler,
            expectedAccountGeneration: accountContext?.htmlContent
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
}
