import Foundation

protocol CanonicalEmailContentLoading: Sendable {
    func loadCanonicalEmailContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        allowRecovery: Bool
    ) async -> CanonicalEmailContent?

    func loadCanonicalEmailContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        allowRecovery: Bool,
        expectedAccountGeneration: HTMLContentAccountGeneration?
    ) async -> CanonicalEmailContent?

    func recoverCanonicalEmailContent(
        messageId: String,
        bodyText: String?
    ) async -> CanonicalEmailContent?

    func recoverCanonicalEmailContent(
        messageId: String,
        bodyText: String?,
        expectedAccountGeneration: HTMLContentAccountGeneration?
    ) async -> CanonicalEmailContent?

    func currentHTMLSourceSignature(
        messageId: String,
        bodyStorageURI: String?
    ) -> String?
}

extension CanonicalEmailContentLoading {
    func currentHTMLSourceSignature(
        messageId: String,
        bodyStorageURI: String?
    ) -> String? {
        nil
    }
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
        await loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: allowRecovery,
            expectedAccountGeneration: nil
        )
    }

    func loadCanonicalEmailContent(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        allowRecovery: Bool,
        expectedAccountGeneration: HTMLContentAccountGeneration?
    ) async -> CanonicalEmailContent? {
        guard let accountGeneration = expectedAccountGeneration ?? contentHandler.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return nil
        }
        let normalizedPlainText = Self.normalizedMeaningfulPlainText(from: bodyText)

        if contentHandler.htmlFileExists(for: messageId, expectedGeneration: accountGeneration),
           let html = canonicalHTMLSource(from: contentHandler.loadHTML(
               for: messageId,
               expectedGeneration: accountGeneration
           )) {
            return logAndReturn(
                CanonicalEmailContent(
                    html: html,
                    plainText: normalizedPlainText,
                    sourceKind: .html,
                    sourceLocation: .messageFile
                ),
                messageId: messageId,
                accountGeneration: accountGeneration
            )
        }

        if let bodyStorageURI,
           let url = StorageURIResolver.resolve(bodyStorageURI),
           FileManager.default.fileExists(atPath: url.path),
           let html = canonicalHTMLSource(from: contentHandler.loadHTML(
               from: url,
               expectedGeneration: accountGeneration
           )) {
            return logAndReturn(
                CanonicalEmailContent(
                    html: html,
                    plainText: normalizedPlainText,
                    sourceKind: .html,
                    sourceLocation: .storageURI
                ),
                messageId: messageId,
                accountGeneration: accountGeneration
            )
        }

        let rawExtraction = bodyText.map(RawEmailSourceSanitizer.extractHTMLResult(from:)) ?? .notRawSource
        if rawExtraction != .notRawSource {
            let decodeStart = CFAbsoluteTimeGetCurrent()
            OriginalEmailTelemetry.log(
                event: "original_email_decode_started",
                messageId: messageId,
                source: "raw_cache",
                detail: "stage=raw_mime_extract"
            )

            if case .html(let rawSourceHTML) = rawExtraction,
               let html = canonicalHTMLSource(from: rawSourceHTML) {
                OriginalEmailTelemetry.log(
                    event: "original_email_decode_completed",
                    messageId: messageId,
                    source: "raw_cache",
                    duration: CFAbsoluteTimeGetCurrent() - decodeStart,
                    detail: "stage=raw_mime_extract"
                )

                let content = CanonicalEmailContent(
                    html: html,
                    plainText: normalizedPlainText,
                    sourceKind: .html,
                    sourceLocation: .rawSourceHTML
                )

                // Capture every dependent cache epoch before the write. If an
                // account transition happens after this point, the save or
                // each subsequent invalidation rejects the stale generation
                // instead of evicting the newly reopened account's content.
                guard let invalidationContext = await HTMLContentLoader.shared
                    .captureInvalidationAccountContext(
                        expectedAccountGeneration: accountGeneration
                    ),
                    let processedTextGeneration = await ProcessedTextCache.shared
                        .captureAccountGeneration(),
                    contentHandler.isAccountGenerationCurrent(accountGeneration) else {
                    return nil
                }

                let writeStart = CFAbsoluteTimeGetCurrent()
                if contentHandler.saveHTML(
                    html,
                    for: messageId,
                    expectedGeneration: accountGeneration
                ) != nil {
                    OriginalEmailTelemetry.log(
                        event: "original_email_db_write_completed",
                        messageId: messageId,
                        source: "raw_cache",
                        duration: CFAbsoluteTimeGetCurrent() - writeStart,
                        detail: "storage=html_file"
                    )
                    await HTMLContentLoader.shared.invalidateContent(
                        messageId: messageId,
                        accountContext: invalidationContext
                    )
                    await ProcessedTextCache.shared.invalidate(
                        messageId: messageId,
                        expectedAccountGeneration: processedTextGeneration,
                        invalidatesRenderedMessage: false
                    )
                    guard contentHandler.isAccountGenerationCurrent(accountGeneration) else {
                        return nil
                    }
                    await MainActor.run {
                        HTMLContentLoader.postContentSourceDidChange(
                            messageId: messageId,
                            sourceSignature: content.sourceSignature
                        )
                    }
                } else {
                    OriginalEmailTelemetry.log(
                        event: "original_email_db_write_failed",
                        messageId: messageId,
                        source: "raw_cache",
                        duration: CFAbsoluteTimeGetCurrent() - writeStart,
                        detail: "storage=html_file failure_reason=save_html_failed"
                    )
                }

                return logAndReturn(
                    content,
                    messageId: messageId,
                    accountGeneration: accountGeneration
                )
            }

            OriginalEmailTelemetry.log(
                event: "original_email_decode_failed",
                messageId: messageId,
                source: "raw_cache",
                duration: CFAbsoluteTimeGetCurrent() - decodeStart,
                detail: "stage=raw_mime_extract failure_reason=no_html_part"
            )
        }

        if allowRecovery,
           let recoveredContent = await recoverCanonicalEmailContent(
            messageId: messageId,
            bodyText: bodyText,
            accountGeneration: accountGeneration
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
            messageId: messageId,
            accountGeneration: accountGeneration
        )
    }

    func recoverCanonicalEmailContent(
        messageId: String,
        bodyText: String?
    ) async -> CanonicalEmailContent? {
        await recoverCanonicalEmailContent(
            messageId: messageId,
            bodyText: bodyText,
            expectedAccountGeneration: nil
        )
    }

    func recoverCanonicalEmailContent(
        messageId: String,
        bodyText: String?,
        expectedAccountGeneration: HTMLContentAccountGeneration?
    ) async -> CanonicalEmailContent? {
        guard let accountGeneration = expectedAccountGeneration ?? contentHandler.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return nil
        }
        guard let recoveryGeneration = await recoveryService.captureAccountGeneration(),
              contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return nil
        }
        return await recoverCanonicalEmailContent(
            messageId: messageId,
            bodyText: bodyText,
            accountGeneration: accountGeneration,
            recoveryGeneration: recoveryGeneration
        )
    }

    private func recoverCanonicalEmailContent(
        messageId: String,
        bodyText: String?,
        accountGeneration: HTMLContentAccountGeneration,
        recoveryGeneration: HTMLContentRecoveryAccountGeneration? = nil
    ) async -> CanonicalEmailContent? {
        guard contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return nil
        }
        let resolvedRecoveryGeneration: HTMLContentRecoveryAccountGeneration
        if let recoveryGeneration {
            resolvedRecoveryGeneration = recoveryGeneration
        } else if let captured = await recoveryService.captureAccountGeneration() {
            resolvedRecoveryGeneration = captured
        } else {
            return nil
        }
        guard contentHandler.isAccountGenerationCurrent(accountGeneration),
              let recoveredHTML = await recoveryService.recoverHTMLContent(
                  messageId: messageId,
                  expectedAccountGeneration: resolvedRecoveryGeneration
              ) else {
            return nil
        }
        guard contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return nil
        }

        let decodeStart = CFAbsoluteTimeGetCurrent()
        OriginalEmailTelemetry.log(
            event: "original_email_decode_started",
            messageId: messageId,
            source: "provider_fetch",
            detail: "stage=recovered_html_canonicalize"
        )

        guard let html = canonicalHTMLSource(from: recoveredHTML) else {
            OriginalEmailTelemetry.log(
                event: "original_email_decode_failed",
                messageId: messageId,
                source: "provider_fetch",
                duration: CFAbsoluteTimeGetCurrent() - decodeStart,
                detail: "stage=recovered_html_canonicalize failure_reason=invalid_html"
            )
            return nil
        }

        OriginalEmailTelemetry.log(
            event: "original_email_decode_completed",
            messageId: messageId,
            source: "provider_fetch",
            duration: CFAbsoluteTimeGetCurrent() - decodeStart,
            detail: "stage=recovered_html_canonicalize"
        )

        return logAndReturn(
            CanonicalEmailContent(
                html: html,
                plainText: Self.normalizedMeaningfulPlainText(from: bodyText),
                sourceKind: .recoveredHTML,
                sourceLocation: .recoveredHTML
            ),
            messageId: messageId,
            accountGeneration: accountGeneration
        )
    }

    func currentHTMLSourceSignature(
        messageId: String,
        bodyStorageURI: String?
    ) -> String? {
        guard let accountGeneration = contentHandler.captureAccountGeneration() else {
            return nil
        }
        return contentHandler.canonicalHTMLSourceSignature(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            expectedGeneration: accountGeneration
        )
    }

    private func logAndReturn(
        _ content: CanonicalEmailContent,
        messageId: String,
        accountGeneration: HTMLContentAccountGeneration
    ) -> CanonicalEmailContent? {
        guard contentHandler.isAccountGenerationCurrent(accountGeneration) else {
            return nil
        }
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

    private static func normalizedPlainTextFallback(from text: String) -> String {
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

    static func normalizedMeaningfulPlainText(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let normalized = normalizedPlainTextFallback(from: text)
        let nonWhitespace = normalized.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return nonWhitespace.isEmpty ? nil : normalized
    }

    private static func looksQuotedPrintable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("=\r\n") ||
            lower.contains("=\n") ||
            lower.contains("=3d") ||
            lower.contains("=3c") ||
            lower.contains("=3e")
    }
}
