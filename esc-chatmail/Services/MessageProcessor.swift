import Foundation
import CoreData

class MessageProcessor {
    private let emailTextProcessor = EmailTextProcessor.self
    private let emailNormalizer = EmailNormalizer.self

    func processGmailMessage(_ gmailMessage: GmailMessage, myAliases: Set<String>, in context: NSManagedObjectContext) async -> ProcessedMessage? {
        guard let payload = gmailMessage.payload,
              let headers = payload.headers else { return nil }

        // Debug: dump MIME structure to understand attachment handling
        dumpMimeStructure(payload, messageId: gmailMessage.id)

        var processedMessage = ProcessedMessage()
        processedMessage.id = gmailMessage.id
        processedMessage.gmThreadId = gmailMessage.threadId ?? ""
        processedMessage.snippet = gmailMessage.snippet

        // Process internal date
        if let internalDateStr = gmailMessage.internalDate,
           let internalDateMs = Double(internalDateStr) {
            processedMessage.internalDate = Date(timeIntervalSince1970: internalDateMs / 1000)
        } else {
            processedMessage.internalDate = Date()
        }

        // Process headers
        processedMessage.headers = extractHeaders(from: headers, myAliases: myAliases)

        // Process content (may fetch large body parts via API)
        let content = await extractContent(from: payload, messageId: gmailMessage.id)
        processedMessage.htmlBody = content.html
        processedMessage.plainTextBody = resolvedPlainTextBody(
            plainText: content.plainText,
            html: content.html
        )
        processedMessage.cleanedSnippet = createCleanedSnippet(html: content.html, plainText: content.plainText, snippet: gmailMessage.snippet, isFromMe: processedMessage.headers.isFromMe)

        // Process labels
        if let labelIds = gmailMessage.labelIds {
            processedMessage.labelIds = labelIds
            processedMessage.isUnread = labelIds.contains("UNREAD")
        }

        // Detect if this is a newsletter/promotion
        processedMessage.isNewsletter = isNewsletterOrPromotion(
            labelIds: processedMessage.labelIds,
            headers: processedMessage.headers
        )

        // Check for attachments (exclude body parts that we fetched as content)
        processedMessage.hasAttachments = checkForAttachments(in: payload)
        processedMessage.attachmentInfo = extractAttachments(from: payload)
        if !processedMessage.attachmentInfo.isEmpty {
            processedMessage.hasAttachments = true
        }

        return processedMessage
    }

    private func resolvedPlainTextBody(plainText: String?, html: String?) -> String? {
        if let plainText {
            let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return plainText
            }
        }

        guard let html else { return nil }
        let extracted = TextProcessing.extractPlainText(from: html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return extracted.isEmpty ? nil : extracted
    }

    // MARK: - Newsletter Detection

    /// Signals that indicate an email may be a newsletter or promotion
    enum NewsletterSignal: String, CaseIterable {
        // Gmail categorization
        case gmailPromotions = "gmail_promotions"
        case gmailUpdates = "gmail_updates"
        case gmailForums = "gmail_forums"

        // Headers
        case listUnsubscribe = "list_unsubscribe"
        case listId = "list_id"
        case precedenceBulk = "precedence_bulk"

        // Sender patterns - strong indicators
        case senderNoreply = "sender_noreply"
        case senderNewsletter = "sender_newsletter"
        case senderMarketing = "sender_marketing"

        // Sender patterns - weak indicators
        case senderNotifications = "sender_notifications"
        case senderSupport = "sender_support"

        // Other signals
        case replyToMismatch = "reply_to_mismatch"
        case highRecipientCount = "high_recipient_count"
        case veryHighRecipientCount = "very_high_recipient_count"

        // Subject patterns - strong
        case subjectDiscount = "subject_discount"
        case subjectNewsletter = "subject_newsletter"
        case subjectUrgency = "subject_urgency"

        // Subject patterns - weak
        case subjectPeriodic = "subject_periodic"
    }

    /// Result of newsletter detection with score and triggered signals
    struct NewsletterDetectionResult {
        let isNewsletter: Bool
        let score: Int
        let signals: [NewsletterSignal]

        static let threshold = 50
    }

    /// Calculates newsletter score using weighted signals
    /// Returns true if score >= 50 (threshold)
    private func isNewsletterOrPromotion(labelIds: [String], headers: ProcessedHeaders) -> Bool {
        calculateNewsletterScore(labelIds: labelIds, headers: headers).isNewsletter
    }

    /// Calculates newsletter detection score with detailed signal tracking
    func calculateNewsletterScore(labelIds: [String], headers: ProcessedHeaders) -> NewsletterDetectionResult {
        var score = 0
        var signals: [NewsletterSignal] = []

        // Gmail categorization (ML-based, generally accurate)
        if labelIds.contains("CATEGORY_PROMOTIONS") {
            score += 40
            signals.append(.gmailPromotions)
        }
        if labelIds.contains("CATEGORY_UPDATES") {
            score += 30
            signals.append(.gmailUpdates)
        }
        if labelIds.contains("CATEGORY_FORUMS") {
            score += 20
            signals.append(.gmailForums)
        }

        // Mailing list headers
        if headers.listUnsubscribe != nil {
            score += 35
            signals.append(.listUnsubscribe)
        }
        if headers.listId != nil {
            score += 25
            signals.append(.listId)
        }

        // Precedence header
        if let precedence = headers.precedence?.lowercased(),
           ["bulk", "list", "junk"].contains(precedence) {
            score += 30
            signals.append(.precedenceBulk)
        }

        // Sender patterns - use else-if to only count the strongest matching signal
        // This prevents double-counting when an address like "marketing-notifications@" matches multiple patterns
        if let from = headers.from?.lowercased() {
            // Check patterns in order of specificity/strength (strongest first)
            let newsletterPatterns = ["newsletter@", "marketing@", "promo@", "promotions@"]
            let strongPatterns = ["noreply@", "no-reply@", "donotreply@", "do-not-reply@"]
            let notificationPatterns = ["notifications@", "alerts@", "digest@", "updates@", "news@", "mailer@"]
            let supportPatterns = ["support@", "hello@", "team@", "info@"]

            if newsletterPatterns.contains(where: { from.contains($0) }) {
                // Strongest indicator - explicit newsletter/marketing sender
                score += 35
                signals.append(.senderNewsletter)
            } else if strongPatterns.contains(where: { from.contains($0) }) {
                // Strong indicator - no-reply addresses
                score += 25
                signals.append(.senderNoreply)
            } else if notificationPatterns.contains(where: { from.contains($0) }) {
                // Weak indicator - could be legitimate notifications
                score += 20
                signals.append(.senderNotifications)
            } else if supportPatterns.contains(where: { from.contains($0) }) {
                // Very weak indicator - often legitimate
                score += 5
                signals.append(.senderSupport)
            }
        }

        // Reply-To mismatch (weak signal - many legitimate uses)
        if let from = headers.from?.lowercased(),
           let replyTo = headers.replyTo?.lowercased() {
            let fromEmail = emailNormalizer.extractEmail(from: from)?.lowercased()
            let replyToEmail = emailNormalizer.extractEmail(from: replyTo)?.lowercased()
            if let fromEmail = fromEmail, let replyToEmail = replyToEmail,
               fromEmail != replyToEmail {
                score += 10
                signals.append(.replyToMismatch)
            }
        }

        // Recipient count (higher threshold to reduce false positives)
        let totalRecipients = headers.to.count + headers.cc.count
        if totalRecipients > 50 {
            score += 25
            signals.append(.veryHighRecipientCount)
        } else if totalRecipients > 20 {
            score += 15
            signals.append(.highRecipientCount)
        }

        // Subject patterns
        if let subject = headers.subject?.lowercased() {
            // Strong marketing indicators
            let discountPatterns = ["% off", "sale", "discount"]
            if discountPatterns.contains(where: { subject.contains($0) }) {
                score += 15
                signals.append(.subjectDiscount)
            }

            let newsletterPatterns = ["newsletter", "digest"]
            if newsletterPatterns.contains(where: { subject.contains($0) }) {
                score += 20
                signals.append(.subjectNewsletter)
            }

            let urgencyPatterns = ["unsubscribe", "limited time", "don't miss", "act now", "expires", "special offer"]
            if urgencyPatterns.contains(where: { subject.contains($0) }) {
                score += 20
                signals.append(.subjectUrgency)
            }

            // Weak indicators (could be legitimate recurring updates)
            let periodicPatterns = ["weekly", "monthly"]
            if periodicPatterns.contains(where: { subject.contains($0) }) {
                score += 5
                signals.append(.subjectPeriodic)
            }
        }

        let isNewsletter = score >= NewsletterDetectionResult.threshold

        #if DEBUG
        if !signals.isEmpty {
            Log.debug("Newsletter detection: score=\(score) threshold=\(NewsletterDetectionResult.threshold) isNewsletter=\(isNewsletter) signals=\(signals.map { $0.rawValue })", category: .sync)
        }
        #endif

        return NewsletterDetectionResult(isNewsletter: isNewsletter, score: score, signals: signals)
    }
    
    private func extractHeaders(from headers: [MessageHeader], myAliases: Set<String>) -> ProcessedHeaders {
        var processedHeaders = ProcessedHeaders()

        for header in headers {
            switch header.name.lowercased() {
            case "subject":
                processedHeaders.subject = header.value
            case "from":
                processedHeaders.from = header.value
                if let email = emailNormalizer.extractEmail(from: header.value) {
                    processedHeaders.isFromMe = myAliases.contains(normalizedEmail(email))
                }
            case "to":
                processedHeaders.to = parseEmailAddresses(from: header.value)
            case "cc":
                processedHeaders.cc = parseEmailAddresses(from: header.value)
            case "bcc":
                processedHeaders.bcc = parseEmailAddresses(from: header.value)
            case "reply-to":
                processedHeaders.replyTo = header.value
            case "in-reply-to":
                processedHeaders.inReplyTo = header.value
            case "references":
                processedHeaders.references = header.value.split(separator: " ").map(String.init)
            case "message-id":
                processedHeaders.messageId = header.value
            case "list-unsubscribe":
                processedHeaders.listUnsubscribe = header.value
            case "list-id":
                processedHeaders.listId = header.value
            case "precedence":
                processedHeaders.precedence = header.value
            default:
                break
            }
        }

        return processedHeaders
    }
    
    private func parseEmailAddresses(from headerValue: String) -> [EmailAddress] {
        return headerValue.split(separator: ",").compactMap { emailStr in
            let trimmed = emailStr.trimmingCharacters(in: .whitespaces)
            guard let email = emailNormalizer.extractEmail(from: trimmed) else { return nil }
            return EmailAddress(
                email: emailNormalizer.normalize(email),
                displayName: emailNormalizer.extractDisplayName(from: trimmed)
            )
        }
    }
    
    private func extractContent(from part: MessagePart, messageId: String) async -> (html: String?, plainText: String?) {
        var html: String? = nil
        var plainText: String? = nil

        // Use a box to allow mutation in nested async function
        actor ContentBox {
            var html: String? = nil
            var plainText: String? = nil

            func setHTML(_ value: String?) { html = value }
            func setPlainText(_ value: String?) { plainText = value }
            func getHTML() -> String? { html }
            func getPlainText() -> String? { plainText }
        }

        let box = ContentBox()

        func traverse(_ part: MessagePart) async {
            let resolvedMimeType = resolvedMimeType(for: part)

            if isHTMLMimeType(resolvedMimeType) {
                if let data = part.body?.data {
                    await box.setHTML(decodeBody(data, headers: part.headers))
                } else if let attachmentId = part.body?.attachmentId {
                    // Large HTML body - fetch via attachment API
                    await box.setHTML(await fetchLargeBodyContent(attachmentId: attachmentId, messageId: messageId, headers: part.headers))
                }
            } else if isPlainTextMimeType(resolvedMimeType) {
                if let data = part.body?.data {
                    await box.setPlainText(decodeBody(data, headers: part.headers))
                } else if let attachmentId = part.body?.attachmentId {
                    // Large plain text body - fetch via attachment API
                    await box.setPlainText(await fetchLargeBodyContent(attachmentId: attachmentId, messageId: messageId, headers: part.headers))
                }
            }

            if let parts = part.parts {
                for subpart in parts {
                    await traverse(subpart)
                    let hasHTML = await box.getHTML() != nil
                    let hasPlainText = await box.getPlainText() != nil
                    if hasHTML && hasPlainText { break }
                }
            }
        }

        await traverse(part)

        // Don't clean HTML content here - preserve original for display
        // The cleaning will be done only when creating snippets

        html = await box.getHTML()
        plainText = await box.getPlainText()

        return (html, plainText)
    }

    /// Fetches large body content via the attachment API
    /// Gmail returns body parts larger than ~25KB with attachmentId instead of inline data
    private func fetchLargeBodyContent(attachmentId: String, messageId: String, headers: [MessageHeader]?) async -> String? {
        do {
            let apiClient = await MainActor.run { GmailAPIClient.shared }
            let attachmentData = try await apiClient.getAttachment(messageId: messageId, attachmentId: attachmentId)
            let text = String(decoding: attachmentData, as: UTF8.self)
            return decodeTransferEncoding(text, headers: headers)
        } catch {
            Log.warning("Failed to fetch large body \(attachmentId) for message \(messageId): \(error)", category: .sync)
            return nil
        }
    }
    
    private func decodeBody(_ data: String, headers: [MessageHeader]?) -> String? {
        guard let decodedData = decodeBase64Data(data) else {
            return nil
        }
        let text = String(decoding: decodedData, as: UTF8.self)
        return decodeTransferEncoding(text, headers: headers)
    }

    private func decodeBase64Data(_ data: String) -> Data? {
        // Gmail uses URL-safe base64 (RFC 4648) and may include incidental whitespace/newlines.
        // Be permissive here; decode failures would drop the entire HTML/plain body.
        let base64String = data
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: " ", with: "")

        var paddedBase64 = base64String
        let remainder = base64String.count % 4
        if remainder > 0 {
            paddedBase64 = base64String + String(repeating: "=", count: 4 - remainder)
        }

        guard let decodedData = Data(base64Encoded: paddedBase64, options: [.ignoreUnknownCharacters]) else {
            Log.debug("Failed to decode Base64", category: .sync)
            return nil
        }

        return decodedData
    }

    private func resolvedMimeType(for part: MessagePart) -> String? {
        if let directMimeType = part.mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !directMimeType.isEmpty {
            return directMimeType
        }

        guard let contentType = part.headers?
            .first(where: { $0.name.lowercased() == "content-type" })?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !contentType.isEmpty else {
            return nil
        }

        return contentType
    }

    private func isHTMLMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !mimeType.isEmpty else {
            return false
        }

        return mimeType.hasPrefix("text/html")
    }

    private func isPlainTextMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !mimeType.isEmpty else {
            return false
        }

        return mimeType.hasPrefix("text/plain")
    }

    private func decodeTransferEncoding(_ text: String, headers: [MessageHeader]?) -> String {
        let encoding = headers?.first { $0.name.lowercased() == "content-transfer-encoding" }?.value.lowercased()
        if encoding?.contains("quoted-printable") == true {
            return QuotedPrintableDecoder.decode(text)
        }
        if encoding == nil, looksQuotedPrintable(text) {
            return QuotedPrintableDecoder.decode(text)
        }
        return text
    }

    private func looksQuotedPrintable(_ text: String) -> Bool {
        if text.contains("=\r\n") || text.contains("=\n") {
            return true
        }
        let lower = text.lowercased()
        if lower.contains("=3d") || lower.contains("=3c") || lower.contains("=3e") {
            return true
        }
        return false
    }
    
    private func createCleanedSnippet(html: String?, plainText: String?, snippet: String?, isFromMe: Bool) -> String? {
        if let html = html {
            let snippetReadyHTML = prepareHTMLForSnippet(html)
            // First try to remove quoted content for snippets
            let cleanedHTML = EmailTextProcessor.removeQuotedFromHTML(snippetReadyHTML) ?? snippetReadyHTML
            let plainFromHTML = EmailTextProcessor.extractPlainFromHTML(cleanedHTML)
            let result = EmailTextProcessor.createCleanSnippet(from: plainFromHTML, maxLength: Int.max, firstSentenceOnly: false)

            // If quote removal stripped everything, try without HTML quote removal
            if result.isEmpty {
                let plainFromRawHTML = EmailTextProcessor.extractPlainFromHTML(snippetReadyHTML)
                let fallbackResult = EmailTextProcessor.createCleanSnippet(from: plainFromRawHTML, maxLength: Int.max, firstSentenceOnly: false)
                if !fallbackResult.isEmpty {
                    return fallbackResult
                }
            } else {
                return result
            }
        }

        if let plainText = plainText {
            let sanitizedPlainText = RawEmailSourceSanitizer.extractDisplayText(from: plainText)
            let result = EmailTextProcessor.createCleanSnippet(from: sanitizedPlainText, maxLength: Int.max, firstSentenceOnly: false)
            if !result.isEmpty {
                return result
            }
        }

        if let snippet = snippet {
            let sanitizedSnippet = RawEmailSourceSanitizer.extractDisplayText(from: snippet)
            let result = EmailTextProcessor.createCleanSnippet(from: sanitizedSnippet, maxLength: Int.max, firstSentenceOnly: false)
            if !result.isEmpty {
                return result
            }
            // Ultimate fallback: return raw snippet if all cleaning strips it
            return sanitizedSnippet.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    /// Prepares HTML for snippet extraction by removing metadata and hidden preheaders
    /// that frequently pollute conversation list previews (e.g., title tags, Outlook comments).
    private func prepareHTMLForSnippet(_ html: String) -> String {
        var cleaned = html

        // Remove HTML head content (title, meta, style, mso settings, etc.)
        cleaned = cleaned.replacingOccurrences(
            of: "<head\\b[^>]*>[\\s\\S]*?</head>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove HTML comments, including Outlook conditional blocks.
        cleaned = cleaned.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: "",
            options: [.regularExpression]
        )

        // Remove hidden preheader/style-hiding elements.
        cleaned = cleaned.replacingOccurrences(
            of: "<([a-zA-Z0-9]+)\\b[^>]*style\\s*=\\s*['\"][^'\"]*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden|mso-hide\\s*:\\s*all|max-height\\s*:\\s*0|opacity\\s*:\\s*0|font-size\\s*:\\s*0)[^'\"]*['\"][^>]*>[\\s\\S]*?</\\1>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        return cleaned
    }
    
    /// Debug helper to dump MIME structure
    private func dumpMimeStructure(_ part: MessagePart, messageId: String, depth: Int = 0) {
        #if DEBUG
        let indent = String(repeating: "  ", count: depth)
        let attachId = part.body?.attachmentId ?? "none"
        let filename = part.filename ?? ""
        let size = part.body?.size ?? 0
        let mime = part.mimeType ?? "unknown"
        let partCount = part.parts?.count ?? 0

        Log.debug("MIME_DEBUG \(indent)[\(messageId)] mime=\(mime) file='\(filename)' attachId=\(attachId != "none" ? "YES" : "no") size=\(size) parts=\(partCount)", category: .sync)

        if let subparts = part.parts {
            for subpart in subparts {
                dumpMimeStructure(subpart, messageId: messageId, depth: depth + 1)
            }
        }
        #endif
    }

    private func checkForAttachments(in part: MessagePart) -> Bool {
        if part.body?.attachmentId != nil {
            return true
        }
        
        if let parts = part.parts {
            return parts.contains { checkForAttachments(in: $0) }
        }
        
        return false
    }
    
    private func extractAttachments(from part: MessagePart) -> [AttachmentInfo] {
        var attachments: [AttachmentInfo] = []
        var seenIds: Set<String> = []
        var seenInlineFingerprints: Set<String> = []

        func traverse(_ part: MessagePart) {
            #if DEBUG
            // Log parts that have attachment indicators for debugging
            let hasAttachmentId = part.body?.attachmentId != nil
            let hasFilename = part.filename.map { !$0.isEmpty } ?? false
            if hasAttachmentId || hasFilename {
                Log.debug("ATTACH_DEBUG Part: mime=\(part.mimeType ?? "nil") file=\(part.filename ?? "nil") attachId=\(hasAttachmentId) size=\(part.body?.size ?? 0)", category: .sync)
            }
            #endif

            let trimmedFilename = part.filename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let mimeType = part.mimeType ?? "application/octet-stream"

            // Extract Content-ID header for inline attachments (cid: URLs)
            // Content-ID format is typically: <unique-id@domain.com>
            // We strip the angle brackets for matching against cid: URLs
            let contentId = part.headers?.first(where: { $0.name.lowercased() == "content-id" })?.value
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))

            // Only process actual file parts, not multipart containers.
            // Also skip duplicate attachment IDs.
            if let attachmentId = part.body?.attachmentId,
               !(part.mimeType?.hasPrefix("multipart/") ?? false),
               !seenIds.contains(attachmentId) {
                seenIds.insert(attachmentId)

                let attachment = AttachmentInfo(
                    id: attachmentId,
                    filename: resolvedAttachmentFilename(from: trimmedFilename, mimeType: mimeType),
                    mimeType: mimeType,
                    size: part.body?.size ?? 0,
                    contentId: contentId,
                    inlineData: nil
                )
                attachments.append(attachment)
            } else if !(part.mimeType?.hasPrefix("multipart/") ?? false),
                      let encodedData = part.body?.data,
                      shouldTreatInlineDataPartAsAttachment(part, trimmedFilename: trimmedFilename, contentId: contentId),
                      let decodedData = decodeBase64Data(encodedData) {
                let size = part.body?.size ?? decodedData.count
                let inlineFingerprint = "\(part.partId ?? "")|\(trimmedFilename)|\(mimeType)|\(contentId ?? "")|\(size)"
                if !seenInlineFingerprints.contains(inlineFingerprint) {
                    seenInlineFingerprints.insert(inlineFingerprint)

                    let attachment = AttachmentInfo(
                        id: "local_inline_\(UUID().uuidString)",
                        filename: resolvedAttachmentFilename(from: trimmedFilename, mimeType: mimeType),
                        mimeType: mimeType,
                        size: size,
                        contentId: contentId,
                        inlineData: decodedData
                    )
                    attachments.append(attachment)
                }
            }

            if let parts = part.parts {
                for subpart in parts {
                    traverse(subpart)
                }
            }
        }

        traverse(part)

        #if DEBUG
        if attachments.isEmpty && checkForAttachments(in: part) {
            Log.debug("checkForAttachments=true but extractAttachments=0. Part structure may need review.", category: .sync)
        }
        Log.debug("ATTACH_DEBUG extractAttachments result: \(attachments.count) attachments found", category: .sync)
        #endif

        return attachments
    }

    private func shouldTreatInlineDataPartAsAttachment(
        _ part: MessagePart,
        trimmedFilename: String,
        contentId: String?
    ) -> Bool {
        let contentDisposition = part.headers?
            .first(where: { $0.name.lowercased() == "content-disposition" })?
            .value
            .lowercased() ?? ""

        let hasAttachmentDisposition = contentDisposition.contains("attachment")
        let hasInlineDisposition = contentDisposition.contains("inline")
        let isInlineCIDImage = (part.mimeType?.lowercased().hasPrefix("image/") ?? false) && (contentId?.isEmpty == false)

        if hasAttachmentDisposition {
            return true
        }

        if !trimmedFilename.isEmpty {
            return true
        }

        if hasInlineDisposition && contentId?.isEmpty == false {
            return true
        }

        return isInlineCIDImage
    }

    private func resolvedAttachmentFilename(from trimmedFilename: String, mimeType: String) -> String {
        guard !trimmedFilename.isEmpty else {
            let ext = AttachmentPaths.fileExtension(for: mimeType)
            return "attachment.\(ext)"
        }
        return trimmedFilename
    }
}

// MARK: - Data Models

struct ProcessedMessage: Sendable {
    var id: String = ""
    var gmThreadId: String = ""
    var snippet: String?
    var cleanedSnippet: String?
    var internalDate: Date = Date()
    var headers: ProcessedHeaders = ProcessedHeaders()
    var htmlBody: String?
    var plainTextBody: String?
    var labelIds: [String] = []
    var isUnread: Bool = false
    var isNewsletter: Bool = false
    var hasAttachments: Bool = false
    var attachmentInfo: [AttachmentInfo] = []
}

struct ProcessedHeaders: Sendable {
    var subject: String?
    var from: String?
    var replyTo: String?
    var to: [EmailAddress] = []
    var cc: [EmailAddress] = []
    var bcc: [EmailAddress] = []
    var isFromMe: Bool = false
    var inReplyTo: String?
    var references: [String] = []
    var messageId: String?
    var listUnsubscribe: String?
    var listId: String?
    var precedence: String?
}

struct EmailAddress: Sendable {
    let email: String
    let displayName: String?
}

struct AttachmentInfo: Sendable {
    let id: String
    let filename: String
    let mimeType: String
    let size: Int
    let contentId: String?
    let inlineData: Data?

    init(
        id: String,
        filename: String,
        mimeType: String,
        size: Int,
        contentId: String?,
        inlineData: Data? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentId = contentId
        self.inlineData = inlineData
    }
}
