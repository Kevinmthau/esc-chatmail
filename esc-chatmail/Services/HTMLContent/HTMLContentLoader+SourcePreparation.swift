import Foundation

// Source preparation — turns a resolved HTML (or plain-text) source into a
// sanitized, wrapped, quality-checked display result. canonicalHTMLSource
// normalizes a candidate source; wrappedHTMLIfMeaningful sanitizes + wraps it
// and rejects empty / low-quality output; approvedReplyQuotedHTML handles the
// reply-compose quoting path; qualityFallbackResult is the plain-text fallback;
// warmRemoteImageAttachmentFallback pre-warms remote-image attachment swaps.
extension HTMLContentLoader {

    func qualityFallbackResult(_ text: String) -> HTMLLoadResult {
        HTMLLoadResult(
            html: nil,
            source: .qualityFallback,
            presentation: .nativePlainText,
            nativeText: text
        )
    }

    func approvedReplyQuotedHTML(
        from html: String?,
        plainText: String?,
        senderEmail: String?,
        subject: String?
    ) -> String? {
        guard let canonicalHTML = canonicalHTMLSource(from: html) else {
            return nil
        }

        let sanitizedHTML = sanitizer.sanitize(
            canonicalHTML,
            rewriteModernImageFormatHints: false
        )
        guard HTMLMeaningfulContentChecker.hasMeaningfulContent(sanitizedHTML) else {
            return nil
        }

        let evaluation = qualityEvaluator.evaluate(
            html: sanitizedHTML,
            plainText: plainText,
            senderEmail: senderEmail,
            subject: subject
        )
        guard evaluation.presentation == .html else {
            return nil
        }

        return sanitizedHTML
    }

    func canonicalHTMLSource(from html: String?) -> String? {
        guard let html else { return nil }

        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowercased = trimmed.lowercased()

        // Older builds could persist the generated plain-text "See More" fallback as if it were
        // the original HTML. Treat those wrappers as stale cache artifacts so we can continue on
        // to raw-source extraction or Gmail recovery and show the real email instead.
        if lowercased.contains("esc-plain-text-styles") ||
            lowercased.contains("esc-plain-main") ||
            lowercased.contains("esc-plain-details") {
            return nil
        }

        return trimmed
    }

    func wrappedHTMLIfMeaningful(
        _ html: String,
        sourceSignature: String,
        messageId: String,
        plainText: String?,
        senderEmail: String?,
        subject: String?,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode,
        displayPurpose: HTMLDisplayPurpose,
        originalHTMLPreference: OriginalEmailHTMLPreference
    ) async -> PreparedLoadResult? {
        let preparedHTML = prepareHTMLForDisplay(html, cleanupMode: cleanupMode)

        // Full original-email reader open path (preferHTML): JavaScript is disabled in every
        // reader/preview WebView config, links are gated by the navigation policy, and the wrapper
        // emits a hardened CSP. Keep a narrow active-markup/event-handler strip so scripts, meta
        // refresh, frames, base/link/object/svg markup cannot load or navigate, but preserve inert
        // visible content such as noscript fallbacks and CTA/receipt text in button/label markup.
        // Keep the existing href/src URL safety pass so unsupported links stay inert and unsafe
        // image sources never reach WebKit. Broader URL/CSS/tracking rewrites are redundant work
        // here and can corrupt complex nested-table HTML. Remote http(s) images load directly via
        // WebKit when possible; risky modern-format image candidates still use the original
        // nonblocking attachment fallback below. The automatic-preference original path
        // (chat-derived previews, quality fallback) keeps full sanitization below.
        if displayPurpose == .original, originalHTMLPreference == .preferHTML {
            let activeMarkupSafeHTML = sanitizer.removeOriginalReaderActiveMarkupAndEventHandlers(preparedHTML)
            let safeHTML = sanitizer.sanitizeOriginalReaderURLs(activeMarkupSafeHTML)
            guard HTMLMeaningfulContentChecker.hasMeaningfulContent(safeHTML) else {
                Log.debug("wrappedHTMLIfMeaningful: original preferHTML content not meaningful for \(messageId) (len=\(safeHTML.count))", category: .ui)
                return nil
            }

            let cachedRewrite = await remoteImageAttachmentFallback.cachedRiskyModernFormatImages(
                in: safeHTML,
                senderEmail: senderEmail
            )
            if cachedRewrite.hasPendingUpdates {
                warmRemoteImageAttachmentFallback(
                    in: safeHTML,
                    currentHTML: cachedRewrite.html,
                    messageId: messageId,
                    senderEmail: senderEmail,
                    scope: .riskyModernFormat
                )
            }

            let wrapped = sanitizer.wrapSanitizedHTMLForDisplay(
                cachedRewrite.html,
                isDarkMode: isDarkMode,
                displayPurpose: .original,
                headSerialization: .stringOnly
            )
            guard HTMLMeaningfulContentChecker.hasMeaningfulContent(wrapped) else {
                Log.debug("wrappedHTMLIfMeaningful: wrapped original preferHTML not meaningful for \(messageId) (len=\(wrapped.count))", category: .ui)
                return nil
            }

            return .html(WrappedHTMLResult(html: wrapped, shouldCache: !cachedRewrite.hasPendingUpdates))
        }

        let rewriteImageHints = displayPurpose != .original
        let sanitizedHTML = sanitizer.sanitize(
            preparedHTML,
            rewriteModernImageFormatHints: rewriteImageHints
        )
        guard HTMLMeaningfulContentChecker.hasMeaningfulContent(sanitizedHTML) else {
            Log.debug("wrappedHTMLIfMeaningful: sanitized HTML not meaningful for \(messageId) (len=\(sanitizedHTML.count))", category: .ui)
            return nil
        }

        if displayPurpose == .original, originalHTMLPreference == .automatic {
            let parsedEmail = await parsedEmailProvider.parsedEmail(
                messageId: messageId,
                sourceSignature: [
                    sourceSignature,
                    "sanitized",
                    "cleanup:\(cleanupMode.rawValue)",
                    "purpose:\(displayPurpose.rawValue)"
                ].joined(separator: "|"),
                canonicalHTML: sanitizedHTML,
                includeRenderQuality: true
            )
            let evaluation = qualityEvaluator.evaluate(
                parsedEmail: parsedEmail,
                html: sanitizedHTML,
                plainText: plainText,
                senderEmail: senderEmail,
                subject: subject
            )

            if evaluation.presentation == .nativePlainText,
               let fallbackText = evaluation.fallbackText {
                Log.debug(
                    "wrappedHTMLIfMeaningful: original quality fallback for \(messageId): \(evaluation.summary)",
                    category: .ui
                )
                return .nativePlainText(fallbackText)
            }
        }

        let rewrittenHTML: String
        let shouldCache: Bool
        switch displayPurpose {
        case .original:
            let cachedRewrite = await remoteImageAttachmentFallback.cachedInlineAttachmentStyleImages(
                in: sanitizedHTML,
                senderEmail: senderEmail
            )
            if cachedRewrite.hasPendingUpdates {
                warmRemoteImageAttachmentFallback(
                    in: sanitizedHTML,
                    currentHTML: cachedRewrite.html,
                    messageId: messageId,
                    senderEmail: senderEmail
                )
            }
            // Skip a second full sanitize pass when the attachment-image rewrite changed nothing
            // (the common case for the full-view open). Re-sanitizing identical, already-sanitized
            // HTML is wasted CPU on the hot path and a known corruption risk for complex
            // nested-table newsletters; only re-sanitize when the rewrite actually mutated the HTML.
            if cachedRewrite.html == sanitizedHTML {
                rewrittenHTML = sanitizedHTML
            } else {
                rewrittenHTML = sanitizer.sanitize(
                    cachedRewrite.html,
                    rewriteModernImageFormatHints: rewriteImageHints
                )
            }
            shouldCache = !cachedRewrite.hasPendingUpdates
        case .preview:
            let cachedRewrite = await remoteImageAttachmentFallback.previewInlineAttachmentStyleImages(
                in: sanitizedHTML,
                senderEmail: senderEmail
            )
            if cachedRewrite.hasPendingUpdates {
                warmRemoteImageAttachmentFallback(
                    in: sanitizedHTML,
                    currentHTML: cachedRewrite.html,
                    messageId: messageId,
                    senderEmail: senderEmail
                )
            }
            rewrittenHTML = cachedRewrite.html
            shouldCache = !cachedRewrite.hasPendingUpdates
        }

        // Use wrapSanitizedHTMLForDisplay to avoid re-sanitizing already-sanitized HTML.
        // Triple sanitization (sanitize → sanitize → wrapHTMLForDisplay.sanitize) was corrupting
        // complex newsletter HTML with nested tables and encoded attributes.
        let wrapped = sanitizer.wrapSanitizedHTMLForDisplay(
            rewrittenHTML,
            isDarkMode: isDarkMode,
            displayPurpose: displayPurpose
        )
        guard HTMLMeaningfulContentChecker.hasMeaningfulContent(wrapped) else {
            Log.debug("wrappedHTMLIfMeaningful: wrapped HTML not meaningful for \(messageId) (len=\(wrapped.count))", category: .ui)
            return nil
        }

        return .html(WrappedHTMLResult(html: wrapped, shouldCache: shouldCache))
    }

    private func warmRemoteImageAttachmentFallback(
        in html: String,
        currentHTML: String,
        messageId: String,
        senderEmail: String?,
        scope: RemoteImageFallbackWarmupScope = .attachmentStyle
    ) {
        let remoteImageAttachmentFallback = self.remoteImageAttachmentFallback
        // Warm rewritten image data promptly so a near-immediate reopen can pick up the cached
        // result instead of waiting behind low-priority detached work.
        Task(priority: .userInitiated) {
            let warmedRewrite: HTMLRemoteImageAttachmentFallback.CachedRewriteResult
            switch scope {
            case .attachmentStyle:
                _ = await remoteImageAttachmentFallback.inlineAttachmentStyleImages(
                    in: html,
                    senderEmail: senderEmail
                )
                warmedRewrite = await remoteImageAttachmentFallback.cachedInlineAttachmentStyleImages(
                    in: html,
                    senderEmail: senderEmail
                )
            case .riskyModernFormat:
                _ = await remoteImageAttachmentFallback.inlineRiskyModernFormatImages(
                    in: html,
                    senderEmail: senderEmail
                )
                warmedRewrite = await remoteImageAttachmentFallback.cachedRiskyModernFormatImages(
                    in: html,
                    senderEmail: senderEmail
                )
            }

            if !warmedRewrite.hasPendingUpdates, warmedRewrite.html != currentHTML {
                Log.debug(
                    "Warmed attachment-style remote image fallback for message \(messageId)",
                    category: .ui
                )
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.remoteImageAttachmentFallbackDidWarmNotification,
                        object: self,
                        userInfo: [Self.remoteImageAttachmentFallbackMessageIdUserInfoKey: messageId]
                    )
                }
            }
        }
    }
}
