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

/// The one fingerprint of a reader body: `"<UTF-8 count>:<SHA-256 prefix>"`. Every key of the
/// wrapped original HTML uses it (`FullEmailWebViewPreRenderKey`, the prepared payload's
/// `htmlFingerprint`, `EmailReaderArtifact.renderSignature`), so a fingerprint computed once, off the main actor, by
/// the warm (`WarmedOriginalEmailHTML`) can stand in for each of them byte for byte (architecture
/// review 2026-11, `web-content-rendering#4`).
enum ReaderContentFingerprint {
    static func make(_ text: String) -> String {
        countMainThreadComputationForTesting()
        return uncounted(text)
    }

    /// `make` without the main-thread count, for a debug check of a fingerprint handed in.
    static func uncounted(_ text: String) -> String {
        "\(text.utf8.count):\(StableFingerprint.sha256Prefix(text))"
    }

    private static let mainThreadComputationLock = NSLock()
    private static var mainThreadComputations = 0

    /// How many fingerprints were computed on the main thread, for the test that pins an open and
    /// a checkout computing none there.
    static var mainThreadComputationCountForTesting: Int {
        mainThreadComputationLock.withLock { mainThreadComputations }
    }

    private static func countMainThreadComputationForTesting() {
        guard Thread.isMainThread else { return }
        mainThreadComputationLock.withLock { mainThreadComputations += 1 }
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

    /// `bodyFingerprint` is the body's `ReaderContentFingerprint`, when the caller already has it
    /// (a prepared payload computed it off the main actor); without it, it is computed here.
    init(
        messageID: String,
        sourceSignature: String,
        renderSignature: String? = nil,
        body: Body,
        bodyFingerprint: String? = nil,
        metadata: EmailMetadataSnapshot,
        inlineAttachmentAvailabilitySignature: String? = nil,
        sourceKind: CanonicalEmailSourceKind,
        sourceLocation: CanonicalEmailSourceLocation,
        hasHTMLSource: Bool,
        producedAt: Date = Date()
    ) {
        // A fingerprint handed in stands in for the body's in the render signature, so one for
        // other content would let an adopted view show what the signature does not say. Debug
        // builds check it (a hash of the body on the main actor, which release builds skip).
        assert(
            bodyFingerprint.map { $0 == ReaderContentFingerprint.uncounted(body.content) } ?? true,
            "EmailReaderArtifact was handed a fingerprint of other content"
        )
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
            bodyFingerprint: bodyFingerprint ?? ReaderContentFingerprint.make(body.content),
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
        bodyFingerprint: String,
        inlineAttachmentAvailabilitySignature: String?,
        sourceKind: CanonicalEmailSourceKind,
        sourceLocation: CanonicalEmailSourceLocation,
        hasHTMLSource: Bool
    ) -> String {
        [
            "reader:v1",
            "message:\(messageID)",
            "source:\(sourceSignature)",
            "body:\(body.kind):\(bodyFingerprint)",
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
