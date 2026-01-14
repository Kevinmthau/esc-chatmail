import Foundation
@testable import esc_chatmail

/// Fluent builder for creating GmailMessage objects (API responses) in tests.
///
/// Usage:
/// ```swift
/// let message = GmailMessageBuilder()
///     .withId("msg-123")
///     .withThreadId("thread-456")
///     .withSubject("Test Email")
///     .withFrom("sender@example.com", name: "John Doe")
///     .withLabels(["INBOX", "UNREAD"])
///     .build()
/// ```
final class GmailMessageBuilder {
    private var id: String = UUID().uuidString
    private var threadId: String = UUID().uuidString
    private var labelIds: [String] = ["INBOX"]
    private var snippet: String = "This is a test message snippet..."
    private var historyId: String = "12345"
    private var internalDate: String = String(Int(Date().timeIntervalSince1970 * 1000))
    private var sizeEstimate: Int = 1024

    // Header values
    private var subject: String = "Test Subject"
    private var fromEmail: String = "sender@example.com"
    private var fromName: String? = "Test Sender"
    private var toEmails: [String] = ["recipient@example.com"]
    private var toNames: [String?] = [nil]
    private var ccEmails: [String] = []
    private var ccNames: [String?] = []
    private var date: String = "Mon, 1 Jan 2024 12:00:00 +0000"
    private var messageId: String?
    private var inReplyTo: String?
    private var references: String?

    // Body
    private var bodyText: String? = "This is the plain text body."
    private var bodyHtml: String?
    private var attachments: [(filename: String, mimeType: String, attachmentId: String)] = []

    // MARK: - Fluent Setters

    func withId(_ id: String) -> Self {
        self.id = id
        return self
    }

    func withThreadId(_ threadId: String) -> Self {
        self.threadId = threadId
        return self
    }

    func withLabels(_ labels: [String]) -> Self {
        self.labelIds = labels
        return self
    }

    func inInbox() -> Self {
        if !labelIds.contains("INBOX") {
            labelIds.append("INBOX")
        }
        return self
    }

    func unread() -> Self {
        if !labelIds.contains("UNREAD") {
            labelIds.append("UNREAD")
        }
        return self
    }

    func read() -> Self {
        labelIds.removeAll { $0 == "UNREAD" }
        return self
    }

    func starred() -> Self {
        if !labelIds.contains("STARRED") {
            labelIds.append("STARRED")
        }
        return self
    }

    func sent() -> Self {
        if !labelIds.contains("SENT") {
            labelIds.append("SENT")
        }
        labelIds.removeAll { $0 == "INBOX" }
        return self
    }

    func archived() -> Self {
        labelIds.removeAll { $0 == "INBOX" }
        return self
    }

    func withSnippet(_ snippet: String) -> Self {
        self.snippet = snippet
        return self
    }

    func withHistoryId(_ historyId: String) -> Self {
        self.historyId = historyId
        return self
    }

    func withInternalDate(_ date: Date) -> Self {
        self.internalDate = String(Int(date.timeIntervalSince1970 * 1000))
        return self
    }

    func withInternalDateMillis(_ millis: Int) -> Self {
        self.internalDate = String(millis)
        return self
    }

    func daysAgo(_ days: Int) -> Self {
        let date = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return withInternalDate(date)
    }

    func hoursAgo(_ hours: Int) -> Self {
        let date = Calendar.current.date(byAdding: .hour, value: -hours, to: Date()) ?? Date()
        return withInternalDate(date)
    }

    func withSubject(_ subject: String) -> Self {
        self.subject = subject
        return self
    }

    func withFrom(_ email: String, name: String? = nil) -> Self {
        self.fromEmail = email
        self.fromName = name
        return self
    }

    func withTo(_ emails: [String], names: [String?]? = nil) -> Self {
        self.toEmails = emails
        self.toNames = names ?? Array(repeating: nil, count: emails.count)
        return self
    }

    func withCc(_ emails: [String], names: [String?]? = nil) -> Self {
        self.ccEmails = emails
        self.ccNames = names ?? Array(repeating: nil, count: emails.count)
        return self
    }

    func withMessageId(_ messageId: String) -> Self {
        self.messageId = messageId
        return self
    }

    func withInReplyTo(_ inReplyTo: String) -> Self {
        self.inReplyTo = inReplyTo
        return self
    }

    func withReferences(_ references: String) -> Self {
        self.references = references
        return self
    }

    func withBodyText(_ text: String) -> Self {
        self.bodyText = text
        return self
    }

    func withBodyHtml(_ html: String) -> Self {
        self.bodyHtml = html
        return self
    }

    func withAttachment(filename: String, mimeType: String = "application/octet-stream", attachmentId: String? = nil) -> Self {
        let attId = attachmentId ?? UUID().uuidString
        attachments.append((filename: filename, mimeType: mimeType, attachmentId: attId))
        return self
    }

    func withSizeEstimate(_ size: Int) -> Self {
        self.sizeEstimate = size
        return self
    }

    // MARK: - Build

    /// Builds the GmailMessage with configured values.
    func build() -> GmailMessage {
        let headers = buildHeaders()
        let body = buildBody()
        let parts = buildParts()
        let hasParts = parts != nil && !(parts?.isEmpty ?? true)

        let payload = MessagePart(
            partId: "",
            mimeType: hasParts ? "multipart/mixed" : "text/plain",
            filename: nil,
            headers: headers,
            body: hasParts ? nil : body,
            parts: hasParts ? parts : nil
        )

        return GmailMessage(
            id: id,
            threadId: threadId,
            labelIds: labelIds,
            snippet: snippet,
            historyId: historyId,
            internalDate: internalDate,
            payload: payload,
            sizeEstimate: sizeEstimate
        )
    }

    // MARK: - Private Helpers

    private func buildHeaders() -> [MessageHeader] {
        var headers: [MessageHeader] = []

        headers.append(MessageHeader(name: "Subject", value: subject))
        headers.append(MessageHeader(name: "From", value: formatAddress(email: fromEmail, name: fromName)))
        headers.append(MessageHeader(name: "To", value: formatAddresses(emails: toEmails, names: toNames)))
        headers.append(MessageHeader(name: "Date", value: date))

        if !ccEmails.isEmpty {
            headers.append(MessageHeader(name: "Cc", value: formatAddresses(emails: ccEmails, names: ccNames)))
        }

        if let messageId = messageId {
            headers.append(MessageHeader(name: "Message-ID", value: messageId))
        } else {
            headers.append(MessageHeader(name: "Message-ID", value: "<\(id)@test.example.com>"))
        }

        if let inReplyTo = inReplyTo {
            headers.append(MessageHeader(name: "In-Reply-To", value: inReplyTo))
        }

        if let references = references {
            headers.append(MessageHeader(name: "References", value: references))
        }

        return headers
    }

    private func buildBody() -> MessageBody? {
        guard let text = bodyText else { return nil }
        let data = text.data(using: .utf8)?.base64EncodedString()
        return MessageBody(size: text.count, data: data, attachmentId: nil)
    }

    private func buildParts() -> [MessagePart]? {
        var parts: [MessagePart] = []

        // Text part
        if let text = bodyText {
            let textBody = MessageBody(size: text.count, data: text.data(using: .utf8)?.base64EncodedString(), attachmentId: nil)
            if bodyHtml != nil {
                // If we have both text and HTML, wrap in multipart/alternative
                var altParts: [MessagePart] = []
                altParts.append(MessagePart(partId: "0.0", mimeType: "text/plain", filename: nil, headers: nil, body: textBody, parts: nil))

                if let html = bodyHtml {
                    let htmlBody = MessageBody(size: html.count, data: html.data(using: .utf8)?.base64EncodedString(), attachmentId: nil)
                    altParts.append(MessagePart(partId: "0.1", mimeType: "text/html", filename: nil, headers: nil, body: htmlBody, parts: nil))
                }

                parts.append(MessagePart(partId: "0", mimeType: "multipart/alternative", filename: nil, headers: nil, body: nil, parts: altParts))
            } else if !attachments.isEmpty {
                parts.append(MessagePart(partId: "0", mimeType: "text/plain", filename: nil, headers: nil, body: textBody, parts: nil))
            }
        }

        // Attachment parts
        for (index, attachment) in attachments.enumerated() {
            let attachmentBody = MessageBody(size: 0, data: nil, attachmentId: attachment.attachmentId)
            let attachmentPart = MessagePart(
                partId: String(index + 1),
                mimeType: attachment.mimeType,
                filename: attachment.filename,
                headers: [
                    MessageHeader(name: "Content-Disposition", value: "attachment; filename=\"\(attachment.filename)\"")
                ],
                body: attachmentBody,
                parts: nil
            )
            parts.append(attachmentPart)
        }

        return parts.isEmpty ? nil : parts
    }

    private func formatAddress(email: String, name: String?) -> String {
        if let name = name {
            return "\(name) <\(email)>"
        }
        return email
    }

    private func formatAddresses(emails: [String], names: [String?]) -> String {
        let pairs = zip(emails, names)
        return pairs.map { formatAddress(email: $0, name: $1) }.joined(separator: ", ")
    }
}

// MARK: - Convenience Extensions

extension GmailMessageBuilder {
    /// Creates a simple test message with minimal configuration
    static func simple() -> GmailMessage {
        GmailMessageBuilder().build()
    }

    /// Creates an unread inbox message
    static func unreadInbox() -> GmailMessage {
        GmailMessageBuilder()
            .inInbox()
            .unread()
            .build()
    }

    /// Creates a sent message
    static func sentMessage() -> GmailMessage {
        GmailMessageBuilder()
            .sent()
            .withFrom("me@example.com", name: "Me")
            .build()
    }

    /// Creates a reply message
    static func reply(to originalMessageId: String) -> GmailMessage {
        GmailMessageBuilder()
            .withInReplyTo("<\(originalMessageId)@test.example.com>")
            .withReferences("<\(originalMessageId)@test.example.com>")
            .build()
    }

    /// Creates a message with attachments
    static func withAttachments(count: Int = 1) -> GmailMessage {
        var builder = GmailMessageBuilder()
        for i in 0..<count {
            builder = builder.withAttachment(filename: "attachment\(i + 1).pdf")
        }
        return builder.build()
    }
}

// MARK: - GmailProfile Builder

/// Fluent builder for creating GmailProfile objects in tests.
final class GmailProfileBuilder {
    private var emailAddress: String = "test@example.com"
    private var messagesTotal: Int? = 100
    private var threadsTotal: Int? = 50
    private var historyId: String = "12345"

    func withEmail(_ email: String) -> Self {
        self.emailAddress = email
        return self
    }

    func withMessagesTotal(_ total: Int?) -> Self {
        self.messagesTotal = total
        return self
    }

    func withThreadsTotal(_ total: Int?) -> Self {
        self.threadsTotal = total
        return self
    }

    func withHistoryId(_ id: String) -> Self {
        self.historyId = id
        return self
    }

    func build() -> GmailProfile {
        GmailProfile(
            emailAddress: emailAddress,
            messagesTotal: messagesTotal,
            threadsTotal: threadsTotal,
            historyId: historyId
        )
    }
}

// MARK: - HistoryResponse Builder

/// Fluent builder for creating HistoryResponse objects in tests.
final class HistoryResponseBuilder {
    private var history: [HistoryRecord]? = nil
    private var nextPageToken: String? = nil
    private var historyId: String? = "12345"

    func withHistoryId(_ id: String?) -> Self {
        self.historyId = id
        return self
    }

    func withNextPageToken(_ token: String?) -> Self {
        self.nextPageToken = token
        return self
    }

    func withMessagesAdded(_ messages: [GmailMessage]) -> Self {
        let added = messages.map { HistoryMessageAdded(message: $0) }
        let record = HistoryRecord(
            id: UUID().uuidString,
            messages: nil,
            messagesAdded: added,
            messagesDeleted: nil,
            labelsAdded: nil,
            labelsRemoved: nil
        )
        history = (history ?? []) + [record]
        return self
    }

    func withMessagesDeleted(_ messageIds: [String]) -> Self {
        let deleted = messageIds.map { HistoryMessageDeleted(message: MessageListItem(id: $0, threadId: nil)) }
        let record = HistoryRecord(
            id: UUID().uuidString,
            messages: nil,
            messagesAdded: nil,
            messagesDeleted: deleted,
            labelsAdded: nil,
            labelsRemoved: nil
        )
        history = (history ?? []) + [record]
        return self
    }

    func withLabelsAdded(messageId: String, labelIds: [String]) -> Self {
        let added = [HistoryLabelAdded(message: MessageListItem(id: messageId, threadId: nil), labelIds: labelIds)]
        let record = HistoryRecord(
            id: UUID().uuidString,
            messages: nil,
            messagesAdded: nil,
            messagesDeleted: nil,
            labelsAdded: added,
            labelsRemoved: nil
        )
        history = (history ?? []) + [record]
        return self
    }

    func withLabelsRemoved(messageId: String, labelIds: [String]) -> Self {
        let removed = [HistoryLabelRemoved(message: MessageListItem(id: messageId, threadId: nil), labelIds: labelIds)]
        let record = HistoryRecord(
            id: UUID().uuidString,
            messages: nil,
            messagesAdded: nil,
            messagesDeleted: nil,
            labelsAdded: nil,
            labelsRemoved: removed
        )
        history = (history ?? []) + [record]
        return self
    }

    func empty() -> Self {
        history = nil
        return self
    }

    func build() -> HistoryResponse {
        HistoryResponse(
            history: history,
            nextPageToken: nextPageToken,
            historyId: historyId
        )
    }
}
