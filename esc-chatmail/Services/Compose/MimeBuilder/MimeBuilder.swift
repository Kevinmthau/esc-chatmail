import Foundation

struct AttachmentData {
    let data: Data
    let filename: String
    let mimeType: String
}

struct QuotedMessage {
    let senderName: String?
    let senderEmail: String
    let date: Date
    let body: String?
}

struct MimeBuilder {

    static func buildNew(to: [String], from: String, fromName: String? = nil, body: String, subject: String? = nil, attachments: [AttachmentData] = []) -> Data {
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
        let bodyWithQuote = formatReplyBody(body: body, originalMessage: originalMessage)
        if attachments.isEmpty {
            return buildSimpleMessage(to: to, from: from, fromName: fromName, body: bodyWithQuote, subject: subject, inReplyTo: inReplyTo, references: references)
        } else {
            return buildMultipartMessage(to: to, from: from, fromName: fromName, body: bodyWithQuote, subject: subject, inReplyTo: inReplyTo, references: references, attachments: attachments)
        }
    }

    // MARK: - Convenience Overloads

    static func buildNew(to: [String], from: String, body: String) -> Data {
        return buildNew(to: to, from: from, fromName: nil, body: body, subject: nil, attachments: [])
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
