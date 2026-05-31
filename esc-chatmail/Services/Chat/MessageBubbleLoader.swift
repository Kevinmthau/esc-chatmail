import CryptoKit
import Foundation

private final class CachedMessageBubbleHTMLAnalysisBox {
    let value: MessageBubbleHTMLAnalysis

    init(_ value: MessageBubbleHTMLAnalysis) {
        self.value = value
    }
}

final class MessageBubbleHTMLAnalysisCache {
    static let shared = MessageBubbleHTMLAnalysisCache()

    private let cache = NSCache<NSString, CachedMessageBubbleHTMLAnalysisBox>()

    init() {
        cache.countLimit = 512
    }

    func value(forKey key: String) -> MessageBubbleHTMLAnalysis? {
        cache.object(forKey: key as NSString)?.value
    }

    func setValue(_ value: MessageBubbleHTMLAnalysis, forKey key: String) {
        cache.setObject(CachedMessageBubbleHTMLAnalysisBox(value), forKey: key as NSString)
    }
}

struct MessageBubbleSenderRequest: Sendable {
    let email: String
    let personDisplayName: String?
    let personAvatarURL: String?

    /// Display name taken directly from the message's From header, when present.
    /// This is separate from Person.displayName so legacy address-derived stored
    /// names can be rejected without discarding explicit header names.
    let headerDisplayName: String?

    init(
        email: String,
        personDisplayName: String?,
        personAvatarURL: String?,
        headerDisplayName: String? = nil
    ) {
        self.email = email
        self.personDisplayName = personDisplayName
        self.personAvatarURL = personAvatarURL
        self.headerDisplayName = headerDisplayName
    }
}

struct MessageBubbleSenderResult: Sendable, Equatable {
    let name: String?
    let avatarURL: String?
    let imageData: Data?
}

struct MessageBubbleAttachmentSnapshot: Sendable, Equatable {
    let contentId: String?
    let filename: String
    let mimeType: String
    let stateRaw: String
    let localURL: String?
    let byteSize: Int64
    let pageCount: Int16
    let width: Int16
    let height: Int16

    var isReady: Bool {
        stateRaw == Attachment.State.downloaded.rawValue ||
        stateRaw == Attachment.State.uploaded.rawValue
    }
}

struct MessageBubbleHTMLAnalysis: Sendable, Equatable {
    let hasHTMLSource: Bool
    let referencedInlineContentIDs: Set<String>
    let nonDisplayableInlineContentIDs: Set<String>
    let supportsCalendarInvitePreviewCard: Bool

    static let empty = MessageBubbleHTMLAnalysis(
        hasHTMLSource: false,
        referencedInlineContentIDs: [],
        nonDisplayableInlineContentIDs: [],
        supportsCalendarInvitePreviewCard: false
    )

    static func placeholder(hasHTMLSource: Bool) -> MessageBubbleHTMLAnalysis {
        MessageBubbleHTMLAnalysis(
            hasHTMLSource: hasHTMLSource,
            referencedInlineContentIDs: [],
            nonDisplayableInlineContentIDs: [],
            supportsCalendarInvitePreviewCard: false
        )
    }
}

struct MessageBubbleContentRequest: Sendable {
    let messageID: String
    let bodyText: String?
    let chatPreviewText: String?
    let bodyStorageURI: String?
    let cleanedSnippet: String?
    let snippet: String?
    let subject: String?
    let senderName: String?
    let hasHTMLSource: Bool
    let hasAttachments: Bool
    let isFromMe: Bool
    let isForwardedEmail: Bool
    let isLikelyCalendarInvite: Bool
    let effectiveSenderEmail: String?
    let attachmentSnapshots: [MessageBubbleAttachmentSnapshot]

    init(
        messageID: String,
        bodyText: String?,
        chatPreviewText: String? = nil,
        bodyStorageURI: String?,
        cleanedSnippet: String?,
        snippet: String?,
        subject: String?,
        senderName: String?,
        hasHTMLSource: Bool,
        hasAttachments: Bool,
        isFromMe: Bool,
        isForwardedEmail: Bool,
        isLikelyCalendarInvite: Bool,
        effectiveSenderEmail: String?,
        attachmentSnapshots: [MessageBubbleAttachmentSnapshot]
    ) {
        self.messageID = messageID
        self.bodyText = bodyText
        self.chatPreviewText = chatPreviewText
        self.bodyStorageURI = bodyStorageURI
        self.cleanedSnippet = cleanedSnippet
        self.snippet = snippet
        self.subject = subject
        self.senderName = senderName
        self.hasHTMLSource = hasHTMLSource
        self.hasAttachments = hasAttachments
        self.isFromMe = isFromMe
        self.isForwardedEmail = isForwardedEmail
        self.isLikelyCalendarInvite = isLikelyCalendarInvite
        self.effectiveSenderEmail = effectiveSenderEmail
        self.attachmentSnapshots = attachmentSnapshots
    }
}

struct MessageBubbleContentResult: Sendable, Equatable {
    let fullTextContent: String?
    let hasRichHTMLContent: Bool
    let sharedDocumentLinks: [SharedDocumentLink]
    let forwardedDisplayContent: ForwardedMessageDisplayContent?
    let htmlAnalysis: MessageBubbleHTMLAnalysis
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

    static func normalizedContentID(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        var normalized = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))

        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }

        normalized = normalized.removingPercentEncoding ?? normalized
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }
        return normalized.lowercased()
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
        return extractRawReferencedContentIDs(from: html)
    }

    private static func extractRawReferencedContentIDs(from html: String) -> Set<String> {
        var referencedCIDs = Set<String>()
        let cidPrefix = "cid:"
        var searchRange = html.startIndex..<html.endIndex

        while let cidRange = html.range(of: cidPrefix, options: .caseInsensitive, range: searchRange) {
            let startOfCID = cidRange.upperBound
            var endOfCID = startOfCID
            while endOfCID < html.endIndex {
                let char = html[endOfCID]
                if char == "\"" || char == "'" || char == " " || char == "," ||
                    char == ">" || char == "<" {
                    break
                }
                endOfCID = html.index(after: endOfCID)
            }

            if startOfCID < endOfCID,
               let normalizedContentId = normalizedContentID(from: String(html[startOfCID..<endOfCID])) {
                referencedCIDs.insert(normalizedContentId)
            }

            searchRange = endOfCID..<html.endIndex
        }

        return referencedCIDs
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

        let cidPrefix = "cid:"
        var nonDisplayable = Set<String>()
        var searchRange = html.startIndex..<html.endIndex

        while let cidRange = html.range(of: cidPrefix, options: .caseInsensitive, range: searchRange) {
            let startOfCID = cidRange.upperBound
            var endOfCID = startOfCID

            while endOfCID < html.endIndex {
                let char = html[endOfCID]
                if char == "\"" || char == "'" || char == " " || char == "," ||
                    char == ">" || char == "<" {
                    break
                }
                endOfCID = html.index(after: endOfCID)
            }

            defer {
                searchRange = endOfCID..<html.endIndex
            }

            guard startOfCID < endOfCID else { continue }
            guard let normalizedCID = normalizedContentID(from: String(html[startOfCID..<endOfCID])) else {
                continue
            }

            let cidOffset = html.distance(from: html.startIndex, to: startOfCID)
            let trailingThreshold = Int(Double(html.count) * 0.45)
            guard cidOffset >= trailingThreshold else {
                continue
            }

            guard isLikelySignatureInlineAttachment(
                contentID: normalizedCID,
                attachments: attachments
            ) else {
                continue
            }

            nonDisplayable.insert(normalizedCID)
        }

        return nonDisplayable
    }

    private static func isLikelySignatureInlineAttachment(
        contentID: String,
        attachments: [MessageBubbleAttachmentSnapshot]
    ) -> Bool {
        guard let attachment = attachments.first(where: { normalizedContentID(from: $0.contentId) == contentID }) else {
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

        for text in [request.bodyText, request.chatPreviewText, request.cleanedSnippet, request.snippet] {
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
                    MessageBubbleHTMLAnalysisBuilder.normalizedContentID(from: attachment.contentId) ?? "cid:nil",
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
