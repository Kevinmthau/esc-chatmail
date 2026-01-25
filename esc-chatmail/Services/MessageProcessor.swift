import Foundation
import CoreData

class MessageProcessor {
    private let emailTextProcessor = EmailTextProcessor.self
    private let emailNormalizer = EmailNormalizer.self
    
    func processGmailMessage(_ gmailMessage: GmailMessage, myAliases: Set<String>, in context: NSManagedObjectContext) -> ProcessedMessage? {
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
        
        // Process content
        let content = extractContent(from: payload)
        processedMessage.htmlBody = content.html
        processedMessage.plainTextBody = content.plainText
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

        // Check for attachments
        processedMessage.hasAttachments = checkForAttachments(in: payload)
        processedMessage.attachmentInfo = extractAttachments(from: payload)

        return processedMessage
    }

    private func isNewsletterOrPromotion(labelIds: [String], headers: ProcessedHeaders) -> Bool {
        // Check Gmail's automatic categorization
        let promotionLabels = ["CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS"]
        if labelIds.contains(where: { promotionLabels.contains($0) }) {
            return true
        }

        // Check for mailing list headers
        if headers.listUnsubscribe != nil || headers.listId != nil {
            return true
        }

        // Check precedence header
        if let precedence = headers.precedence?.lowercased(),
           ["bulk", "list", "junk"].contains(precedence) {
            return true
        }

        // Check for no-reply sender
        if let from = headers.from?.lowercased() {
            let noReplyPatterns = ["noreply@", "no-reply@", "donotreply@", "do-not-reply@", "newsletter@", "notifications@"]
            if noReplyPatterns.contains(where: { from.contains($0) }) {
                return true
            }
        }

        return false
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
    
    private func extractContent(from part: MessagePart) -> (html: String?, plainText: String?) {
        var html: String? = nil
        var plainText: String? = nil

        func traverse(_ part: MessagePart) {
            if part.mimeType == "text/html", let data = part.body?.data {
                html = decodeBase64(data)
            } else if part.mimeType == "text/plain", let data = part.body?.data {
                plainText = decodeBase64(data)
            }

            if let parts = part.parts {
                for subpart in parts {
                    traverse(subpart)
                    if html != nil && plainText != nil { break }
                }
            }
        }

        traverse(part)

        // Don't clean HTML content here - preserve original for display
        // The cleaning will be done only when creating snippets

        return (html, plainText)
    }
    
    private func decodeBase64(_ data: String) -> String? {
        let base64String = data.replacingOccurrences(of: "-", with: "+")
                              .replacingOccurrences(of: "_", with: "/")
        
        var paddedBase64 = base64String
        let remainder = base64String.count % 4
        if remainder > 0 {
            paddedBase64 = base64String + String(repeating: "=", count: 4 - remainder)
        }
        
        guard let decodedData = Data(base64Encoded: paddedBase64) else {
            Log.debug("Failed to decode Base64", category: .sync)
            return nil
        }
        
        return String(data: decodedData, encoding: .utf8)
    }
    
    private func createCleanedSnippet(html: String?, plainText: String?, snippet: String?, isFromMe: Bool) -> String? {
        if let html = html {
            // First try to remove quoted content for snippets
            let cleanedHTML = EmailTextProcessor.removeQuotedFromHTML(html) ?? html
            let plainFromHTML = EmailTextProcessor.extractPlainFromHTML(cleanedHTML)
            let result = EmailTextProcessor.createCleanSnippet(from: plainFromHTML, maxLength: Int.max, firstSentenceOnly: false)

            // If quote removal stripped everything, try without HTML quote removal
            if result.isEmpty {
                let plainFromRawHTML = EmailTextProcessor.extractPlainFromHTML(html)
                let fallbackResult = EmailTextProcessor.createCleanSnippet(from: plainFromRawHTML, maxLength: Int.max, firstSentenceOnly: false)
                if !fallbackResult.isEmpty {
                    return fallbackResult
                }
            } else {
                return result
            }
        }

        if let plainText = plainText {
            let result = EmailTextProcessor.createCleanSnippet(from: plainText, maxLength: Int.max, firstSentenceOnly: false)
            if !result.isEmpty {
                return result
            }
        }

        if let snippet = snippet {
            let result = EmailTextProcessor.createCleanSnippet(from: snippet, maxLength: Int.max, firstSentenceOnly: false)
            if !result.isEmpty {
                return result
            }
            // Ultimate fallback: return raw snippet if all cleaning strips it
            return snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
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

        func traverse(_ part: MessagePart) {
            #if DEBUG
            // Log parts that have attachment indicators for debugging
            let hasAttachmentId = part.body?.attachmentId != nil
            let hasFilename = part.filename != nil && !part.filename!.isEmpty
            if hasAttachmentId || hasFilename {
                Log.debug("ATTACH_DEBUG Part: mime=\(part.mimeType ?? "nil") file=\(part.filename ?? "nil") attachId=\(hasAttachmentId) size=\(part.body?.size ?? 0)", category: .sync)
            }
            #endif

            // Only process actual file parts, not multipart containers
            // Also skip duplicate attachment IDs
            if let attachmentId = part.body?.attachmentId,
               !(part.mimeType?.hasPrefix("multipart/") ?? false),
               !seenIds.contains(attachmentId) {
                seenIds.insert(attachmentId)

                // Extract Content-ID header for inline attachments (cid: URLs)
                // Content-ID format is typically: <unique-id@domain.com>
                // We strip the angle brackets for matching against cid: URLs
                let contentId = part.headers?.first(where: { $0.name.lowercased() == "content-id" })?.value
                    .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))

                let attachment = AttachmentInfo(
                    id: attachmentId,
                    filename: part.filename ?? "attachment",
                    mimeType: part.mimeType ?? "application/octet-stream",
                    size: part.body?.size ?? 0,
                    contentId: contentId
                )
                attachments.append(attachment)
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
}