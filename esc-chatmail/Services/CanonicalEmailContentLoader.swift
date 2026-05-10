import Foundation

protocol CanonicalEmailContentLoading: Sendable {
    func loadCanonicalEmailContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        allowRecovery: Bool
    ) async -> CanonicalEmailContent?

    func recoverCanonicalEmailContent(
        messageId: String,
        bodyText: String?
    ) async -> CanonicalEmailContent?
}

final class CanonicalEmailContentLoader: CanonicalEmailContentLoading, @unchecked Sendable {
    static let shared = CanonicalEmailContentLoader()

    private let contentHandler: HTMLContentHandler
    private let recoveryService: any HTMLContentRecovering
    private static let previewPaddingRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "[\\u200B\\u200C\\u200D\\uFEFF\\u00A0\\s]{40,}",
            options: []
        )
    }()

    init(
        contentHandler: HTMLContentHandler = .shared,
        recoveryService: any HTMLContentRecovering = HTMLContentRecoveryService.shared
    ) {
        self.contentHandler = contentHandler
        self.recoveryService = recoveryService
    }

    func loadCanonicalEmailContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        allowRecovery: Bool = true
    ) async -> CanonicalEmailContent? {
        let normalizedPlainText = normalizedMeaningfulPlainText(from: bodyText)

        if contentHandler.htmlFileExists(for: messageId),
           let html = canonicalHTMLSource(from: contentHandler.loadHTML(for: messageId)) {
            return logAndReturn(
                CanonicalEmailContent(
                    html: html,
                    plainText: normalizedPlainText,
                    sourceKind: .html,
                    sourceLocation: .messageFile
                ),
                messageId: messageId
            )
        }

        if let bodyStorageURI,
           let url = StorageURIResolver.resolve(bodyStorageURI),
           FileManager.default.fileExists(atPath: url.path),
           let html = canonicalHTMLSource(from: contentHandler.loadHTML(from: url)) {
            return logAndReturn(
                CanonicalEmailContent(
                    html: html,
                    plainText: normalizedPlainText,
                    sourceKind: .html,
                    sourceLocation: .storageURI
                ),
                messageId: messageId
            )
        }

        if let bodyText,
           let rawSourceHTML = RawEmailSourceSanitizer.extractHTMLText(from: bodyText),
           let html = canonicalHTMLSource(from: rawSourceHTML) {
            _ = contentHandler.saveHTML(html, for: messageId)
            HTMLContentLoader.shared.invalidate(messageId: messageId)
            await ProcessedTextCache.shared.invalidate(messageId: messageId)
            return logAndReturn(
                CanonicalEmailContent(
                    html: html,
                    plainText: normalizedPlainText,
                    sourceKind: .html,
                    sourceLocation: .rawSourceHTML
                ),
                messageId: messageId
            )
        }

        if allowRecovery,
           let recoveredContent = await recoverCanonicalEmailContent(
            messageId: messageId,
            bodyText: bodyText
           ) {
            return recoveredContent
        }

        guard let normalizedPlainText else {
            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "CanonicalEmailContentLoader message \(messageId): no canonical content",
                category: .ui
            )
            return nil
        }

        return logAndReturn(
            CanonicalEmailContent(
                html: nil,
                plainText: normalizedPlainText,
                sourceKind: .plainText,
                sourceLocation: .plainText
            ),
            messageId: messageId
        )
    }

    func recoverCanonicalEmailContent(
        messageId: String,
        bodyText: String?
    ) async -> CanonicalEmailContent? {
        guard let recoveredHTML = await recoveryService.recoverHTMLContent(messageId: messageId),
              let html = canonicalHTMLSource(from: recoveredHTML) else {
            return nil
        }

        return logAndReturn(
            CanonicalEmailContent(
                html: html,
                plainText: normalizedMeaningfulPlainText(from: bodyText),
                sourceKind: .recoveredHTML,
                sourceLocation: .recoveredHTML
            ),
            messageId: messageId
        )
    }

    private func logAndReturn(
        _ content: CanonicalEmailContent,
        messageId: String
    ) -> CanonicalEmailContent {
        Log.diagnostic(
            .htmlPreview,
            level: .info,
            "CanonicalEmailContentLoader message \(messageId): sourceKind=\(content.sourceKind.rawValue) sourceLocation=\(content.sourceLocation.rawValue) hasHTML=\(content.hasHTMLSource)",
            category: .ui
        )
        return content
    }

    private func canonicalHTMLSource(from html: String?) -> String? {
        guard let html else { return nil }

        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.lowercased()

        if lowercased.contains("esc-plain-text-styles") ||
            lowercased.contains("esc-plain-main") ||
            lowercased.contains("esc-plain-details") {
            return nil
        }

        return trimmed
    }

    private func normalizedPlainTextFallback(from text: String) -> String {
        var normalized = RawEmailSourceSanitizer.extractDisplayText(from: text)
        normalized = HTMLEntityDecoder.decode(normalized)

        if looksQuotedPrintable(normalized) {
            normalized = QuotedPrintableDecoder.decode(normalized)
            normalized = HTMLEntityDecoder.decode(normalized)
        }

        normalized = normalized
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")

        if let regex = Self.previewPaddingRegex {
            let range = NSRange(location: 0, length: normalized.utf16.count)
            normalized = regex.stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: " ")
        }

        normalized = normalized
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedMeaningfulPlainText(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let normalized = normalizedPlainTextFallback(from: text)
        let nonWhitespace = normalized.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return nonWhitespace.isEmpty ? nil : normalized
    }

    private func looksQuotedPrintable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("=\r\n") ||
            lower.contains("=\n") ||
            lower.contains("=3d") ||
            lower.contains("=3c") ||
            lower.contains("=3e")
    }
}
