import CryptoKit
import Foundation

/// Loads a message's stored body for the chat-bubble compatibility path and
/// computes the source signatures that key its derived-content cache entries.
enum MessageBubbleContentSource {
    static let chatBubblePreviewMode = "chat-bubble-preview"
    static let richContentAnalysisMode = "rich-content-analysis"

    /// Process a single message - can be called from background thread
    static func processMessage(
        messageId: String,
        bodyStorageURI: String? = nil,
        handler: HTMLContentHandler,
        expectedAccountGeneration: HTMLContentAccountGeneration? = nil
    ) -> (plainText: String?, hasRichContent: Bool, quotedParts: [QuotedPart]) {
        let html = loadHTML(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            handler: handler,
            expectedAccountGeneration: expectedAccountGeneration
        )
        if let html {
            let result = ChatBubbleTextProcessor.htmlCompatibilityFallback(
                from: html,
                classifyRichContent: true
            )
            return (result.mainText, result.hasRichContent, result.quotedParts)
        }

        return (nil, false, [])
    }

    /// Derives bubble text from a persisted `bodyText` when no stored HTML
    /// produced any. Shared by the bubble loader's compatibility path and the
    /// blank-preview backfill so a backfilled preview matches what the bubble
    /// already showed.
    static func bodyTextFallback(from bodyText: String) -> ChatBubbleTextProcessingResult {
        let fallbackContent = RawEmailSourceSanitizer.extractHTMLText(from: bodyText) ?? bodyText
        if fallbackContent != bodyText {
            return ChatBubbleTextProcessor.htmlCompatibilityFallback(
                from: fallbackContent,
                classifyRichContent: true
            )
        }
        return ChatBubbleTextProcessor.legacyAutoDetectedFallback(
            from: fallbackContent,
            sanitizeRawEmailSource: true,
            classifyRichContent: true
        )
    }

    /// Classifies rich HTML without deriving chat-bubble text. Used when
    /// Message.chatPreviewText is already the visible bubble source.
    static func classifyRichContent(
        messageId: String,
        bodyStorageURI: String? = nil,
        bodyText: String? = nil,
        handler: HTMLContentHandler,
        expectedAccountGeneration: HTMLContentAccountGeneration? = nil
    ) -> Bool {
        guard let html = richContentHTMLCandidate(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            handler: handler,
            expectedAccountGeneration: expectedAccountGeneration
        ) else {
            return false
        }

        return RichContentClassifier.hasGenuineRichContentAfterCleanup(html)
    }

    private static func richContentHTMLCandidate(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        handler: HTMLContentHandler,
        expectedAccountGeneration: HTMLContentAccountGeneration?
    ) -> String? {
        if let html = loadHTML(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            handler: handler,
            expectedAccountGeneration: expectedAccountGeneration
        ) {
            return html
        }

        guard let bodyText else {
            return nil
        }

        if let rawSourceHTML = RawEmailSourceSanitizer.extractHTMLText(from: bodyText) {
            return rawSourceHTML
        }

        return ChatBubbleTextProcessor.containsHTMLTags(bodyText) ? bodyText : nil
    }

    static func contentSourceSignature(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        handler: HTMLContentHandler,
        expectedAccountGeneration: HTMLContentAccountGeneration? = nil
    ) -> String {
        let htmlSourceSignature = handler.htmlSourceSignature(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            expectedGeneration: expectedAccountGeneration
        )
        if htmlSourceSignature != "missing" {
            return "html:\(htmlSourceSignature)"
        }

        if let bodyTextSignature = bodyTextSignature(for: bodyText) {
            return "body:\(bodyTextSignature)"
        }

        return "empty"
    }

    static func fallbackContentSourceSignature(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        handler: HTMLContentHandler,
        expectedAccountGeneration: HTMLContentAccountGeneration? = nil
    ) -> String {
        let sourceSignature = contentSourceSignature(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            handler: handler,
            expectedAccountGeneration: expectedAccountGeneration
        )
        guard sourceSignature.hasPrefix("html:"),
              let bodyTextSignature = bodyTextSignature(for: bodyText) else {
            return sourceSignature
        }

        return "\(sourceSignature)|fallback-body:\(bodyTextSignature)"
    }

    private static func bodyTextSignature(for bodyText: String?) -> String? {
        guard let bodyText = bodyText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bodyText.isEmpty else {
            return nil
        }

        return sha256Signature(for: bodyText)
    }

    private static func loadHTML(
        messageId: String,
        bodyStorageURI: String?,
        handler: HTMLContentHandler,
        expectedAccountGeneration: HTMLContentAccountGeneration?
    ) -> String? {
        if handler.htmlFileExists(
            for: messageId,
            expectedGeneration: expectedAccountGeneration
        ),
           let html = handler.loadHTML(
               for: messageId,
               expectedGeneration: expectedAccountGeneration
           ) {
            return html
        }

        guard let urlString = bodyStorageURI,
              let url = StorageURIResolver.resolve(urlString),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return handler.loadHTML(from: url, expectedGeneration: expectedAccountGeneration)
    }

    private static func sha256Signature(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }
}
