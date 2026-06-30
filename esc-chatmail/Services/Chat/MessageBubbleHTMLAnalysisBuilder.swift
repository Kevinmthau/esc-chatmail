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
        senderName: String? = nil,
        senderEmail: String? = nil,
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
        senderName: String? = nil,
        senderEmail: String? = nil,
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

        let hardSignatureBoundaryOffset = firstHardSignatureBoundaryOffset(in: lowercasedHTML)
        let replyBoundaryOffset = firstReplyBoundaryOffset(in: lowercasedHTML)
        let signatureSignalHTML = signatureSignalWindow(
            in: lowercasedHTML,
            before: replyBoundaryOffset
        )
        let hasTrailingSignatureSignals = hasSignatureSignals(in: signatureSignalHTML)
        let hasSignatureSectionSignals =
            hardSignatureBoundaryOffset != nil ||
            replyBoundaryOffset != nil ||
            hasTrailingSignatureSignals

        guard hasSignatureSectionSignals else {
            return []
        }

        var nonDisplayable = Set<String>()
        EmailDocument.scanReferencedContentIDs(in: html) { normalizedCID, valueStart in
            let cidOffset = html.distance(from: html.startIndex, to: valueStart)
            let trailingThreshold = Int(Double(html.count) * 0.35)

            let isAfterHardSignatureBoundary = hardSignatureBoundaryOffset.map { cidOffset >= $0 } ?? false
            let isAfterReplyBoundary = replyBoundaryOffset.map { cidOffset >= $0 } ?? false
            let isBeforeReplyBoundary = replyBoundaryOffset.map { cidOffset < $0 } ?? true
            let isTrailingSignatureInlineImage =
                hasTrailingSignatureSignals &&
                isBeforeReplyBoundary &&
                cidOffset >= trailingThreshold

            guard isAfterHardSignatureBoundary ||
                    isAfterReplyBoundary ||
                    isTrailingSignatureInlineImage else {
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

    private static func firstHardSignatureBoundaryOffset(in lowercasedHTML: String) -> Int? {
        signatureHardBoundaryMarkers.compactMap { marker -> Int? in
            guard let range = lowercasedHTML.range(of: marker) else { return nil }
            return lowercasedHTML.distance(from: lowercasedHTML.startIndex, to: range.lowerBound)
        }.min()
    }

    private static func firstReplyBoundaryOffset(in lowercasedHTML: String) -> Int? {
        var candidates: [Int] = []
        for pattern in replyAttributionBoundaryPatterns {
            if let replyAttributionRange = lowercasedHTML.range(
                of: pattern,
                options: .regularExpression
            ) {
                let replyAttributionOffset = lowercasedHTML.distance(
                    from: lowercasedHTML.startIndex,
                    to: replyAttributionRange.lowerBound
                )
                candidates.append(replyAttributionOffset)
            }
        }

        for pattern in replyHeaderBoundaryPatterns {
            if let replyHeaderRange = lowercasedHTML.range(
                of: pattern,
                options: .regularExpression
            ) {
                let replyHeaderOffset = lowercasedHTML.distance(
                    from: lowercasedHTML.startIndex,
                    to: replyHeaderRange.lowerBound
                )
                candidates.append(replyHeaderOffset)
            }
        }

        return candidates.min()
    }

    private static func signatureSignalWindow(in lowercasedHTML: String, before offset: Int?) -> String {
        let searchHTML: Substring
        if let offset {
            let boundaryIndex = lowercasedHTML.index(lowercasedHTML.startIndex, offsetBy: offset)
            searchHTML = lowercasedHTML[..<boundaryIndex]
        } else {
            searchHTML = lowercasedHTML[...]
        }

        return String(searchHTML.suffix(8_000))
    }

    private static func hasSignatureSignals(in lowercasedHTML: String) -> Bool {
        signatureSignOffMarkers.contains { lowercasedHTML.contains($0) } &&
            (
                signatureContactMarkers.contains { lowercasedHTML.contains($0) } ||
                signatureRoleMarkers.contains { lowercasedHTML.contains($0) } ||
                hasStandaloneSignOffBrandingSignals(in: lowercasedHTML)
            )
    }

    private static func hasStandaloneSignOffBrandingSignals(in lowercasedHTML: String) -> Bool {
        guard signatureBrandingMarkers.contains(where: { lowercasedHTML.contains($0) }) else {
            return false
        }

        return lowercasedHTML.range(
            of: standaloneSignOffBeforeBrandingPattern,
            options: .regularExpression
        ) != nil
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
        let contentIDLocalPart = contentID
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? contentID
        let searchableIdentity = [filename, contentID, contentIDLocalPart].joined(separator: " ")
        let hasSignatureKeyword = signatureImageIdentityMarkers.contains { searchableIdentity.contains($0) }

        let isGeneratedInlineName = filename.range(
            of: #"^(?:image|img|inline|cid)[0-9a-f_-]{2,}(?:\.[a-z0-9]{2,5})?$"#,
            options: .regularExpression
        ) != nil

        let isGeneratedInlineContentID = contentIDLocalPart.range(
            of: #"^(?:image|img|inline|cid)[0-9a-f_-]{2,}(?:\.[a-z0-9]{2,5})?$"#,
            options: .regularExpression
        ) != nil

        let hasSmallLogoLikeDimensions =
            attachment.width > 0 &&
            attachment.height > 0 &&
            attachment.width >= attachment.height &&
            attachment.width <= 420 &&
            attachment.height <= 160

        let hasBadgeLikeDimensions =
            attachment.width > 0 &&
            attachment.height > 0 &&
            attachment.width <= 900 &&
            attachment.height <= 900

        let looksLikeGeneratedInlineAsset = isGeneratedInlineName || isGeneratedInlineContentID
        return hasSignatureKeyword || (looksLikeGeneratedInlineAsset && (hasSmallLogoLikeDimensions || hasBadgeLikeDimensions))
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

        return CalendarInvitePreviewBuilder().canBuildPreview(
            canonicalHTML: canonicalHTML,
            bodyText: bodyText,
            cleanedSnippet: cleanedSnippet,
            subject: subject
        )
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

    private static let signatureHardBoundaryMarkers = [
        "gmail_signature",
        "moz-signature",
        "x-apple-signature",
        "data-smartmail=\"gmail_signature\"",
        "class=\"signature",
        "class='signature",
        "id=\"signature",
        "id='signature"
    ]

    // Match standalone reply headers without treating body prose like
    // "here is what I wrote:" as a hard attachment-hiding boundary.
    private static let replyAttributionBoundaryPatterns = [
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:&gt;\s*)?on (?:(?!</?(?:div|p|td|th|li|blockquote|body|html)\b).){1,800}? wrote:\s*(?:<br\s*/?>|</(?:div|p|td|th|li|blockquote)>|[\r\n]|$)"#,
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:&gt;\s*)?(?!(?:here|there|this|that|what|when|where|why|how|following|follow|i|we|you|he|she|they|it|someone|everyone|please|thanks|thank)\b)(?:[a-z][a-z0-9._%+\-']{0,60}\s+){0,2}[a-z][a-z0-9._%+\-']{0,60}(?:\s+&lt;[^&]{1,200}&gt;)?\s+wrote:\s*(?:<br\s*/?>|</(?:div|p|td|th|li|blockquote)>|[\r\n]|$)"#
    ]

    // Match complete rich-text reply headers without treating isolated body
    // labels such as "<b>From:</b> the prototype table" as quote boundaries.
    private static let replyHeaderBoundaryPatterns = [
        #"<(?:b|strong)>\s*from:\s*</(?:b|strong)>[\s\S]{0,2400}<(?:b|strong)>\s*(?:sent|date):\s*</(?:b|strong)>[\s\S]{0,2400}<(?:b|strong)>\s*to:\s*</(?:b|strong)>[\s\S]{0,2400}<(?:b|strong)>\s*subject:\s*</(?:b|strong)>"#
    ]

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
        "twitter",
        "address",
        "unsubscribe"
    ]

    private static let signatureRoleMarkers = [
        "manager",
        "director",
        "president",
        "founder",
        "advisor",
        "broker",
        "realtor",
        "membership",
        "business development",
        "customer engineering"
    ]

    private static let signatureBrandingMarkers = [
        "logo",
        "badge",
        "banner",
        "fortune",
        "best companies",
        "cadence",
        "unleash imagination"
    ]

    private static let standaloneSignOffBeforeBrandingPattern =
        #"(?:^|[\r\n]|<[^>]+>)\s*(?:warmly|best regards|kind regards|regards|sincerely|thanks|thank you|cheers)[,.!]?\s*(?:<br\s*/?>|</(?:div|p|td|th|li)>|[\r\n]|$)[\s\S]{0,1200}(?:logo|badge|banner|fortune|best companies|cadence|unleash imagination)"#

    private static let signatureImageIdentityMarkers = [
        "logo",
        "signature",
        "footer",
        "banner",
        "badge",
        "award",
        "fortune",
        "best-companies",
        "bestcompanies",
        "cadence",
        "linkedin",
        "twitter",
        "facebook",
        "instagram",
        "social",
        "unsubscribe"
    ]
}
