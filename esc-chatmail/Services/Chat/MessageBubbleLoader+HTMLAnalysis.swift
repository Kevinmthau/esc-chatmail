import CryptoKit
import Foundation

extension MessageBubbleLoader {
    func cachedHTMLAnalysis(for request: MessageBubbleContentRequest) async -> MessageBubbleHTMLAnalysis {
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
            subject: request.subject,
            attachmentSnapshots: request.attachmentSnapshots
        )
        return analysis
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
            "attachments:\(attachmentFingerprint(for: request.attachmentSnapshots))"
        ].joined(separator: "|")
    }

    func renderedSourceSignature(for request: MessageBubbleContentRequest) -> String {
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
}
