import Foundation

struct AttachmentData {
    let data: Data
    let filename: String
    let mimeType: String
}

struct InlineAttachmentData {
    let data: Data
    let contentId: String
    let filename: String
    let mimeType: String
}

struct QuotedMessage: Sendable {
    let senderName: String?
    let senderEmail: String
    let date: Date
    let body: String?
    let originalHTML: String?

    init(
        senderName: String?,
        senderEmail: String,
        date: Date,
        body: String?,
        originalHTML: String? = nil
    ) {
        self.senderName = senderName
        self.senderEmail = senderEmail
        self.date = date
        self.body = body
        self.originalHTML = originalHTML
    }
}

struct MimeBuilder {

    static func buildNew(
        to: [String],
        from: String,
        fromName: String? = nil,
        body: String,
        htmlBody: String? = nil,
        subject: String? = nil,
        attachments: [AttachmentData] = [],
        inlineAttachments: [InlineAttachmentData] = []
    ) -> Data {
        // If we have HTML content, use the alternative builder for multipart/alternative structure
        if let htmlBody = htmlBody {
            return buildAlternativeMessage(
                to: to,
                from: from,
                fromName: fromName,
                body: body,
                htmlBody: htmlBody,
                subject: subject,
                inReplyTo: nil,
                references: [],
                attachments: attachments,
                inlineAttachments: inlineAttachments
            )
        }

        // Plain text only
        if attachments.isEmpty {
            return buildSimpleMessage(to: to, from: from, fromName: fromName, body: body, subject: subject, inReplyTo: nil, references: [])
        } else {
            return buildMultipartMessage(to: to, from: from, fromName: fromName, body: body, subject: subject, inReplyTo: nil, references: [], attachments: attachments)
        }
    }

    static func buildReply(
        to: [String],
        from: String,
        fromName: String? = nil,
        body: String,
        subject: String,
        inReplyTo: String?,
        references: [String],
        originalMessage: QuotedMessage? = nil,
        attachments: [AttachmentData] = []
    ) -> Data {
        let plainBodyWithQuote = formatReplyBody(body: body, originalMessage: originalMessage)
        let htmlBodyWithQuote = formatReplyHTMLBody(body: body, originalMessage: originalMessage)
        return buildAlternativeMessage(
            to: to,
            from: from,
            fromName: fromName,
            body: plainBodyWithQuote,
            htmlBody: htmlBodyWithQuote,
            subject: subject,
            inReplyTo: inReplyTo,
            references: references,
            attachments: attachments,
            inlineAttachments: []
        )
    }

    // MARK: - Convenience Overloads

    static func buildNew(to: [String], from: String, body: String) -> Data {
        return buildNew(to: to, from: from, fromName: nil, body: body, htmlBody: nil, subject: nil, attachments: [], inlineAttachments: [])
    }

    static func buildReply(
        to: [String],
        from: String,
        body: String,
        subject: String,
        inReplyTo: String?,
        references: [String]
    ) -> Data {
        return buildReply(to: to, from: from, fromName: nil, body: body, subject: subject, inReplyTo: inReplyTo, references: references, originalMessage: nil, attachments: [])
    }
}
