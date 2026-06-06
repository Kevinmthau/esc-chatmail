import CryptoKit
import Foundation

enum StableFingerprint {
    static func sha256Prefix(_ text: String?, length: Int = 16) -> String {
        guard let text else {
            return "nil"
        }

        let digest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(digest.prefix(max(0, length)))
    }
}

struct OriginalEmailWarmRequest: Equatable, Sendable {
    let messageId: String
    let bodyStorageURI: String?
    let bodyText: String?
    let senderEmail: String?
    let subject: String?
}

protocol OriginalEmailSourceWarming: Sendable {
    func warmOriginalEmailSource(request: OriginalEmailWarmRequest) async
}

extension OriginalEmailSourceLoader: OriginalEmailSourceWarming {
    func warmOriginalEmailSource(request: OriginalEmailWarmRequest) async {
        await warmOriginalEmailSource(
            messageId: request.messageId,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            senderEmail: request.senderEmail,
            subject: request.subject
        )
    }
}

struct EmailMetadataSnapshot: Equatable, Sendable {
    let messageId: String
    let subject: String
    let senderName: String?
    let senderEmail: String?
    let previewText: String?
    let date: Date?

    init(
        messageId: String,
        subject: String,
        senderName: String?,
        senderEmail: String?,
        previewText: String?,
        date: Date?
    ) {
        self.messageId = messageId
        self.subject = subject
        self.senderName = senderName
        self.senderEmail = senderEmail
        self.previewText = previewText
        self.date = date
    }

    init(message: Message) {
        let placeholder = FullEmailPlaceholder(message: message)
        self.init(placeholder: placeholder)
    }

    init(request: OriginalEmailWarmRequest) {
        self.init(
            messageId: request.messageId,
            subject: Self.normalizedSingleLine(request.subject) ?? "No Subject",
            senderName: nil,
            senderEmail: Self.normalizedSingleLine(request.senderEmail),
            previewText: Self.normalizedPreviewText(request.bodyText),
            date: nil
        )
    }

    init(placeholder: FullEmailPlaceholder) {
        self.init(
            messageId: placeholder.messageId,
            subject: placeholder.subject,
            senderName: placeholder.senderName,
            senderEmail: placeholder.senderEmail,
            previewText: placeholder.previewText,
            date: placeholder.date
        )
    }

    private static func normalizedSingleLine(_ value: String?) -> String? {
        FullEmailPlaceholder.normalizedText(value, maxLength: 160)
    }

    private static func normalizedPreviewText(_ value: String?) -> String? {
        FullEmailPlaceholder.normalizedText(value, maxLength: FullEmailPlaceholder.previewCharacterLimit)
    }
}

struct EmailReaderArtifact: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case html(String)
        case plainText(String)

        var content: String {
            switch self {
            case .html(let content):
                return content
            case .plainText(let content):
                return content
            }
        }

        var kind: String {
            switch self {
            case .html:
                return "html"
            case .plainText:
                return "plainText"
            }
        }
    }

    let messageID: String
    let sourceSignature: String
    let renderSignature: String
    let body: Body
    let metadata: EmailMetadataSnapshot
    let inlineAttachmentAvailabilitySignature: String?
    let sourceKind: CanonicalEmailSourceKind
    let sourceLocation: CanonicalEmailSourceLocation
    let hasHTMLSource: Bool
    let producedAt: Date

    init(
        messageID: String,
        sourceSignature: String,
        renderSignature: String? = nil,
        body: Body,
        metadata: EmailMetadataSnapshot,
        inlineAttachmentAvailabilitySignature: String? = nil,
        sourceKind: CanonicalEmailSourceKind,
        sourceLocation: CanonicalEmailSourceLocation,
        hasHTMLSource: Bool,
        producedAt: Date = Date()
    ) {
        self.messageID = messageID
        self.sourceSignature = sourceSignature
        self.body = body
        self.metadata = metadata
        self.inlineAttachmentAvailabilitySignature = inlineAttachmentAvailabilitySignature
        self.sourceKind = sourceKind
        self.sourceLocation = sourceLocation
        self.hasHTMLSource = hasHTMLSource
        self.producedAt = producedAt
        self.renderSignature = renderSignature ?? Self.makeRenderSignature(
            messageID: messageID,
            sourceSignature: sourceSignature,
            body: body,
            inlineAttachmentAvailabilitySignature: inlineAttachmentAvailabilitySignature,
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            hasHTMLSource: hasHTMLSource
        )
    }

    static func make(
        messageID: String,
        source: OriginalEmailSource,
        metadata: EmailMetadataSnapshot,
        message: Message?,
        producedAt: Date = Date()
    ) -> EmailReaderArtifact? {
        switch source.presentation {
        case .html:
            guard let html = source.html else {
                return nil
            }
            return EmailReaderArtifact(
                messageID: messageID,
                sourceSignature: source.sourceSignature,
                body: .html(html),
                metadata: metadata,
                inlineAttachmentAvailabilitySignature: InlineCIDAttachmentAvailabilityFingerprint.make(
                    html: html,
                    message: message
                ),
                sourceKind: source.sourceKind,
                sourceLocation: source.sourceLocation,
                hasHTMLSource: source.hasHTMLSource,
                producedAt: producedAt
            )
        case .nativePlainText:
            guard let plainText = source.plainText else {
                return nil
            }
            return EmailReaderArtifact(
                messageID: messageID,
                sourceSignature: source.sourceSignature,
                body: .plainText(plainText),
                metadata: metadata,
                sourceKind: source.sourceKind,
                sourceLocation: source.sourceLocation,
                hasHTMLSource: source.hasHTMLSource,
                producedAt: producedAt
            )
        }
    }

    private static func makeRenderSignature(
        messageID: String,
        sourceSignature: String,
        body: Body,
        inlineAttachmentAvailabilitySignature: String?,
        sourceKind: CanonicalEmailSourceKind,
        sourceLocation: CanonicalEmailSourceLocation,
        hasHTMLSource: Bool
    ) -> String {
        [
            "reader:v1",
            "message:\(messageID)",
            "source:\(sourceSignature)",
            "body:\(body.kind):\(body.content.utf8.count):\(StableFingerprint.sha256Prefix(body.content))",
            "cid:\(inlineAttachmentAvailabilitySignature ?? "untracked")",
            "kind:\(sourceKind.rawValue)",
            "location:\(sourceLocation.rawValue)",
            "hasHTML:\(hasHTMLSource)"
        ].joined(separator: "|")
    }
}

struct EmailReaderPreparedArtifact: Equatable, Sendable {
    let artifact: EmailReaderArtifact
    let checkoutAvailability: FullEmailOpenPayload.CheckoutAvailability
}
