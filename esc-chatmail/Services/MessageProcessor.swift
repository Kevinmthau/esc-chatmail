import Foundation
import CoreData

class MessageProcessor {
    private let emailTextProcessor = EmailTextProcessor.self
    private let emailNormalizer = EmailNormalizer.self
    
    func processGmailMessage(_ gmailMessage: GmailMessage, myAliases: Set<String>, in context: NSManagedObjectContext) -> ProcessedMessage? {
        guard let payload = gmailMessage.payload,
              let headers = payload.headers else { return nil }
        
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
            let cleanedHTML = emailTextProcessor.removeQuotedFromHTML(html) ?? html
            let plainFromHTML = emailTextProcessor.extractPlainFromHTML(cleanedHTML)
            // Show full content for all emails without any length limit
            return emailTextProcessor.createCleanSnippet(from: plainFromHTML, maxLength: Int.max, firstSentenceOnly: false)
        } else if let plainText = plainText {
            return emailTextProcessor.createCleanSnippet(from: plainText, maxLength: Int.max, firstSentenceOnly: false)
        } else {
            return emailTextProcessor.createCleanSnippet(from: snippet, maxLength: Int.max, firstSentenceOnly: false)
        }
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
        
        func traverse(_ part: MessagePart) {
            if let attachmentId = part.body?.attachmentId {
                let attachment = AttachmentInfo(
                    id: attachmentId,
                    filename: part.filename ?? "attachment",
                    mimeType: part.mimeType ?? "application/octet-stream",
                    size: part.body?.size ?? 0
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
}