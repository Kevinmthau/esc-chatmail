import Foundation

enum MessageBubbleHTMLAnalysisBuilder {
    static func build(
        canonicalHTML: String?,
        parsedEmail: ParsedEmail? = nil,
        hasHTMLSourceHint: Bool,
        isForwardedEmail: Bool,
        isLikelyCalendarInvite: Bool,
        bodyText: String?,
        cleanedSnippet: String?,
        senderName: String?,
        senderEmail: String?,
        subject: String?,
        attachmentSnapshots: [MessageBubbleAttachmentSnapshot]
    ) -> MessageBubbleHTMLAnalysis {
        build(
            canonicalHTML: canonicalHTML,
            parsedEmail: parsedEmail,
            hasHTMLSource: hasHTMLSourceHint || canonicalHTML != nil,
            isForwardedEmail: isForwardedEmail,
            isLikelyCalendarInvite: isLikelyCalendarInvite,
            bodyText: bodyText,
            cleanedSnippet: cleanedSnippet,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject,
            attachmentSnapshots: attachmentSnapshots
        )
    }

    static func build(
        messageID: String,
        bodyStorageURI: String?,
        hasHTMLSourceHint: Bool,
        isForwardedEmail: Bool,
        isLikelyCalendarInvite: Bool,
        bodyText: String?,
        cleanedSnippet: String?,
        senderName: String?,
        senderEmail: String?,
        subject: String?,
        attachmentSnapshots: [MessageBubbleAttachmentSnapshot],
        handler: HTMLContentHandler
    ) -> MessageBubbleHTMLAnalysis {
        let canonicalHTML = loadHTML(
            messageID: messageID,
            bodyStorageURI: bodyStorageURI,
            handler: handler
        )
        let hasHTMLSource = hasHTMLSourceHint || canonicalHTML != nil

        return build(
            canonicalHTML: canonicalHTML,
            parsedEmail: nil,
            hasHTMLSource: hasHTMLSource,
            isForwardedEmail: isForwardedEmail,
            isLikelyCalendarInvite: isLikelyCalendarInvite,
            bodyText: bodyText,
            cleanedSnippet: cleanedSnippet,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject,
            attachmentSnapshots: attachmentSnapshots
        )
    }

    private static func loadHTML(
        messageID: String,
        bodyStorageURI: String?,
        handler: HTMLContentHandler
    ) -> String? {
        if let html = handler.loadHTML(for: messageID) {
            return html
        }

        guard let bodyStorageURI else {
            return nil
        }

        if handler.migrateIfNeeded(from: bodyStorageURI),
           let migratedHTML = handler.loadHTML(for: messageID) {
            return migratedHTML
        }

        guard let resolvedURL = StorageURIResolver.resolve(bodyStorageURI),
              FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        return handler.loadHTML(from: resolvedURL)
    }

    private static func extractNonDisplayableInlineContentIDs(
        from html: String?,
        parsedEmail: ParsedEmail?,
        attachments: [MessageBubbleAttachmentSnapshot]
    ) -> Set<String> {
        guard let html else { return [] }

        let originalReferenced = extractReferencedContentIDs(from: html, parsedEmail: parsedEmail)
        guard !originalReferenced.isEmpty else { return [] }

        let cleaned = cleanedHTMLForAttachmentFiltering(from: html)
        let cleanedReferenced = extractReferencedContentIDs(from: cleaned)
        let removedByHTMLCleanup = originalReferenced.subtracting(cleanedReferenced)
        let likelySignatureInline = extractLikelySignatureInlineContentIDs(
            from: html,
            attachments: attachments
        )

        return removedByHTMLCleanup.union(likelySignatureInline)
    }

    private static func cleanedHTMLForAttachmentFiltering(from html: String) -> String {
        let quotedAndSignature = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures) ?? html
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(quotedAndSignature) {
            return quotedAndSignature
        }

        let quotedOnly = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedOnly) ?? html
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(quotedOnly) {
            return quotedOnly
        }

        return html
    }

    private static func extractReferencedContentIDs(
        from html: String?,
        parsedEmail: ParsedEmail? = nil
    ) -> Set<String> {
        guard let html else { return [] }

        if parsedEmail?.canonicalHTML == html {
            return parsedEmail?.referencedInlineContentIDs ?? []
        }

        if let document = EmailDocument.tryParse(html) {
            return document.referencedInlineContentIDs()
        }
        return EmailDocument.referencedContentIDs(in: html)
    }

    private static func extractLikelySignatureInlineContentIDs(
        from html: String,
        attachments: [MessageBubbleAttachmentSnapshot]
    ) -> Set<String> {
        let lowercasedHTML = html.lowercased()
        guard lowercasedHTML.contains("cid:") else {
            return []
        }

        let trailingWindow = String(lowercasedHTML.suffix(6_000))
        let hasSignatureSectionSignals =
            signatureSignOffMarkers.contains { trailingWindow.contains($0) } &&
            (
                signatureContactMarkers.contains { trailingWindow.contains($0) } ||
                signatureRoleMarkers.contains { trailingWindow.contains($0) }
            )

        guard hasSignatureSectionSignals else {
            return []
        }

        var nonDisplayable = Set<String>()
        EmailDocument.scanReferencedContentIDs(in: html) { normalizedCID, valueStart in
            let cidOffset = html.distance(from: html.startIndex, to: valueStart)
            let trailingThreshold = Int(Double(html.count) * 0.45)
            guard cidOffset >= trailingThreshold else {
                return
            }

            guard isLikelySignatureInlineAttachment(
                contentID: normalizedCID,
                attachments: attachments
            ) else {
                return
            }

            nonDisplayable.insert(normalizedCID)
        }

        return nonDisplayable
    }

    private static func isLikelySignatureInlineAttachment(
        contentID: String,
        attachments: [MessageBubbleAttachmentSnapshot]
    ) -> Bool {
        guard let attachment = attachments.first(where: { EmailDocument.normalizedContentID($0.contentId) == contentID }) else {
            return false
        }

        guard attachment.mimeType.hasPrefix("image/") else {
            return false
        }

        let filename = attachment.filename.lowercased()
        let hasSignatureKeyword =
            filename.contains("logo") ||
            filename.contains("signature") ||
            filename.contains("footer")

        let isGeneratedInlineName = filename.range(
            of: #"^(?:image|img)\d{2,}(?:[_-]\d+)?\.[a-z0-9]{2,5}$"#,
            options: .regularExpression
        ) != nil

        let contentIDLocalPart = contentID
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? contentID
        let isGeneratedInlineContentID = contentIDLocalPart.range(
            of: #"^(?:image|img)\d{2,}(?:[_-]\d+)?(?:\.[a-z0-9]{2,5})?$"#,
            options: .regularExpression
        ) != nil

        let hasLogoLikeDimensions =
            attachment.width > 0 &&
            attachment.height > 0 &&
            attachment.width >= attachment.height &&
            attachment.width <= 320 &&
            attachment.height <= 120

        let looksLikeGeneratedInlineAsset = isGeneratedInlineName || isGeneratedInlineContentID
        return hasSignatureKeyword || (looksLikeGeneratedInlineAsset && hasLogoLikeDimensions)
    }

    private static func supportsCalendarInvitePreviewCard(
        canonicalHTML: String,
        isForwardedEmail: Bool,
        isLikelyCalendarInvite: Bool,
        bodyText: String?,
        cleanedSnippet: String?,
        senderName: String?,
        senderEmail: String?,
        subject: String?
    ) -> Bool {
        guard !isForwardedEmail, isLikelyCalendarInvite else {
            return false
        }

        let previewBuilder = CalendarInvitePreviewBuilder()
        return previewBuilder.buildPreview(
            canonicalHTML: canonicalHTML,
            bodyText: bodyText,
            cleanedSnippet: cleanedSnippet,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject
        ) != nil
    }

    private static func build(
        canonicalHTML: String?,
        parsedEmail: ParsedEmail?,
        hasHTMLSource: Bool,
        isForwardedEmail: Bool,
        isLikelyCalendarInvite: Bool,
        bodyText: String?,
        cleanedSnippet: String?,
        senderName: String?,
        senderEmail: String?,
        subject: String?,
        attachmentSnapshots: [MessageBubbleAttachmentSnapshot]
    ) -> MessageBubbleHTMLAnalysis {
        guard let canonicalHTML else {
            return .placeholder(hasHTMLSource: hasHTMLSource)
        }

        return MessageBubbleHTMLAnalysis(
            hasHTMLSource: hasHTMLSource,
            referencedInlineContentIDs: extractReferencedContentIDs(
                from: canonicalHTML,
                parsedEmail: parsedEmail
            ),
            nonDisplayableInlineContentIDs: extractNonDisplayableInlineContentIDs(
                from: canonicalHTML,
                parsedEmail: parsedEmail,
                attachments: attachmentSnapshots
            ),
            supportsCalendarInvitePreviewCard: supportsCalendarInvitePreviewCard(
                canonicalHTML: canonicalHTML,
                isForwardedEmail: isForwardedEmail,
                isLikelyCalendarInvite: isLikelyCalendarInvite,
                bodyText: bodyText,
                cleanedSnippet: cleanedSnippet,
                senderName: senderName,
                senderEmail: senderEmail,
                subject: subject
            )
        )
    }

    private static let signatureSignOffMarkers = [
        "warmly",
        "best regards",
        "kind regards",
        "regards,",
        "sincerely",
        "thanks,",
        "thank you,",
        "cheers,"
    ]

    private static let signatureContactMarkers = [
        "mailto:",
        "tel:",
        "mobile",
        "phone",
        "www.",
        "linkedin",
        "instagram",
        "twitter"
    ]

    private static let signatureRoleMarkers = [
        "manager",
        "director",
        "president",
        "founder",
        "advisor",
        "broker",
        "realtor",
        "membership"
    ]
}
