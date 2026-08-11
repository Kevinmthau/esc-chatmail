import CryptoKit
import Foundation

enum OriginalEmailTelemetry {
    static func log(
        event: String,
        messageId: String,
        source: String? = nil,
        duration: TimeInterval? = nil,
        detail: String? = nil
    ) {
        var components = [
            "OriginalEmail event=\(event)",
            "message=\(messageId)"
        ]
        if let source {
            components.append("source=\(source)")
        }
        if let duration {
            components.append("duration_ms=\(Int((duration * 1000).rounded()))")
        }
        if let detail {
            components.append(detail)
        }

        Log.diagnostic(
            .htmlPreview,
            level: .info,
            components.joined(separator: " "),
            category: .ui
        )
    }
}

struct OriginalEmailSource: Equatable, Sendable {
    enum Presentation: String, Sendable {
        case html
        case nativePlainText
    }

    let presentation: Presentation
    let html: String?
    let plainText: String?
    let sourceKind: CanonicalEmailSourceKind
    let sourceLocation: CanonicalEmailSourceLocation
    let sourceSignature: String
    let hasHTMLSource: Bool

    var shouldPointBodyStorageURIAtMessageFile: Bool {
        switch sourceLocation {
        case .messageFile, .recoveredHTML:
            return hasHTMLSource
        case .storageURI, .rawSourceHTML, .plainText:
            return false
        }
    }
}

/// The display-ready wrapped original-email HTML produced by a background warm, plus the
/// canonical source signature it was prepared from. Returned so callers (e.g. the pre-rendered
/// full-email WebView pool) can render the exact same HTML the full-view reader will display.
struct WarmedOriginalEmailHTML: Sendable, Equatable {
    let html: String
    let sourceSignature: String
    let sourceKind: CanonicalEmailSourceKind
    let sourceLocation: CanonicalEmailSourceLocation
    let hasHTMLSource: Bool
}

protocol OriginalEmailSourceLoading: Sendable {
    func loadOriginalEmailSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        timeout: TimeInterval
    ) async -> OriginalEmailSource?

    func ensureOriginalEmailAvailable(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?
    ) async -> OriginalEmailSource?
}

extension OriginalEmailSourceLoading {
    /// Default "run to completion" implementation for conformers that don't supply
    /// their own. `.greatestFiniteMagnitude` means "no deadline" — `withSoftTimeout`
    /// treats a non-representable deadline as no timeout and simply awaits the work.
    func ensureOriginalEmailAvailable(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?
    ) async -> OriginalEmailSource? {
        await loadOriginalEmailSource(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject,
            timeout: .greatestFiniteMagnitude
        )
    }
}

private struct OriginalEmailEnsureRequestKey: Hashable, Sendable {
    let accountGeneration: HTMLContentAccountGeneration
    let renderedAccountGeneration: RenderedMessageCacheAccountGeneration
    let messageId: String
    let currentHTMLSourceSignatureFingerprint: String
    let bodyStorageURIFingerprint: String
    let bodyTextFingerprint: String
    let senderEmailFingerprint: String
    let subjectFingerprint: String

    init(
        accountGeneration: HTMLContentAccountGeneration,
        renderedAccountGeneration: RenderedMessageCacheAccountGeneration,
        messageId: String,
        currentHTMLSourceSignature: String?,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?
    ) {
        self.accountGeneration = accountGeneration
        self.renderedAccountGeneration = renderedAccountGeneration
        self.messageId = messageId
        self.currentHTMLSourceSignatureFingerprint = Self.fingerprint(for: currentHTMLSourceSignature)
        self.bodyStorageURIFingerprint = Self.fingerprint(for: bodyStorageURI)
        self.bodyTextFingerprint = Self.fingerprint(for: bodyText)
        self.senderEmailFingerprint = Self.fingerprint(for: senderEmail)
        self.subjectFingerprint = Self.fingerprint(for: subject)
    }

    private static func fingerprint(for text: String?) -> String {
        guard let text else {
            return "nil"
        }

        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(data.count):\(digest)"
    }
}

final class OriginalEmailSourceLoader: OriginalEmailSourceLoading, @unchecked Sendable {
    static let shared = OriginalEmailSourceLoader()

    private let canonicalContentLoader: any CanonicalEmailContentLoading
    private let htmlContentLoader: HTMLContentLoader
    private let renderedMessageCache: RenderedMessageCache
    private let ensureCoordinator = InFlightRequestManager<OriginalEmailEnsureRequestKey, OriginalEmailSource>()

    init(
        canonicalContentLoader: any CanonicalEmailContentLoading = CanonicalEmailContentLoader.shared,
        htmlContentLoader: HTMLContentLoader = .shared,
        renderedMessageCache: RenderedMessageCache = .shared
    ) {
        self.canonicalContentLoader = canonicalContentLoader
        self.htmlContentLoader = htmlContentLoader
        self.renderedMessageCache = renderedMessageCache
    }

    func loadOriginalEmailSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        timeout: TimeInterval = 5.0
    ) async -> OriginalEmailSource? {
        guard let accountGeneration = htmlContentLoader.captureAccountGeneration(),
              let renderedAccountGeneration = await renderedMessageCache.captureAccountGeneration(),
              await accountGenerationsAreCurrent(
                  html: accountGeneration,
                  rendered: renderedAccountGeneration
              ) else {
            return nil
        }
        // Soft timeout: if the load can't finish in `timeout` seconds, return nil
        // while the underlying work keeps running and warms caches
        // (recoveryTasks, inFlightResolutions) so a later load can succeed.
        //
        // We use withSoftTimeout instead of withTaskGroup because withTaskGroup
        // implicitly awaits every child task, and the loading branch contains
        // awaits (notably HTMLContentRecoveryService.recoverHTMLContent's
        // `await task.value` on Gmail API requests) that ignore cooperative
        // cancellation — so a withTaskGroup-based race would leave the spinner
        // up indefinitely. The outer flatten with `??` collapses the two `nil`
        // cases ("timed out" and "loader said no content") into one.
        let result = await withSoftTimeout(seconds: timeout) {
            await self.loadOriginalEmailSourceToCompletion(
                messageId: messageId,
                bodyStorageURI: bodyStorageURI,
                bodyText: bodyText,
                senderEmail: senderEmail,
                subject: subject,
                accountGeneration: accountGeneration,
                renderedAccountGeneration: renderedAccountGeneration
            )
        }
        guard await accountGenerationsAreCurrent(
            html: accountGeneration,
            rendered: renderedAccountGeneration
        ) else {
            return nil
        }
        return result ?? nil
    }

    func ensureOriginalEmailAvailable(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?
    ) async -> OriginalEmailSource? {
        guard let accountGeneration = htmlContentLoader.captureAccountGeneration(),
              let renderedAccountGeneration = await renderedMessageCache.captureAccountGeneration(),
              await accountGenerationsAreCurrent(
                  html: accountGeneration,
                  rendered: renderedAccountGeneration
              ) else {
            return nil
        }
        let currentHTMLSourceSignature = canonicalContentLoader.currentHTMLSourceSignature(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI
        )
        let requestKey = OriginalEmailEnsureRequestKey(
            accountGeneration: accountGeneration,
            renderedAccountGeneration: renderedAccountGeneration,
            messageId: messageId,
            currentHTMLSourceSignature: currentHTMLSourceSignature,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject
        )

        // Coalesce only identical loader inputs and local source snapshots. The
        // same file/URI can be overwritten while recovery is in flight, and the
        // newer source must load immediately.
        let source = await ensureCoordinator.deduplicated(key: requestKey) { [self] in
            guard await accountGenerationsAreCurrent(
                html: accountGeneration,
                rendered: renderedAccountGeneration
            ) else {
                return nil
            }
            let start = CFAbsoluteTimeGetCurrent()
            OriginalEmailTelemetry.log(
                event: "original_email_opened",
                messageId: messageId,
                detail: "priority=userInitiated"
            )

            let source = await loadOriginalEmailSourceToCompletion(
                messageId: messageId,
                bodyStorageURI: bodyStorageURI,
                bodyText: bodyText,
                senderEmail: senderEmail,
                subject: subject,
                accountGeneration: accountGeneration,
                renderedAccountGeneration: renderedAccountGeneration
            )

            let duration = CFAbsoluteTimeGetCurrent() - start
            if let source {
                let sourceName = telemetrySourceName(for: source)
                OriginalEmailTelemetry.log(
                    event: source.sourceLocation == .messageFile || source.sourceLocation == .storageURI
                        ? "original_email_cache_hit"
                        : "original_email_cache_miss",
                    messageId: messageId,
                    source: sourceName,
                    duration: nil,
                    detail: "sourceLocation=\(source.sourceLocation.rawValue)"
                )
                OriginalEmailTelemetry.log(
                    event: "original_email_time_to_first_render_ms",
                    messageId: messageId,
                    source: sourceName,
                    duration: duration,
                    detail: "presentation=\(source.presentation.rawValue)"
                )
            } else {
                OriginalEmailTelemetry.log(
                    event: "original_email_decode_failed",
                    messageId: messageId,
                    duration: duration,
                    detail: "failure_reason=no_recoverable_source"
                )
            }

            return source
        }
        guard await accountGenerationsAreCurrent(
            html: accountGeneration,
            rendered: renderedAccountGeneration
        ) else {
            return nil
        }
        return source
    }

    func loadOriginalEmailSourceToCompletion(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?
    ) async -> OriginalEmailSource? {
        guard let accountGeneration = htmlContentLoader.captureAccountGeneration(),
              let renderedAccountGeneration = await renderedMessageCache.captureAccountGeneration(),
              await accountGenerationsAreCurrent(
                  html: accountGeneration,
                  rendered: renderedAccountGeneration
              ) else {
            return nil
        }
        let source = await loadOriginalEmailSourceToCompletion(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject,
            accountGeneration: accountGeneration,
            renderedAccountGeneration: renderedAccountGeneration
        )
        guard await accountGenerationsAreCurrent(
            html: accountGeneration,
            rendered: renderedAccountGeneration
        ) else {
            return nil
        }
        return source
    }

    private func loadOriginalEmailSourceToCompletion(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        accountGeneration: HTMLContentAccountGeneration,
        renderedAccountGeneration: RenderedMessageCacheAccountGeneration
    ) async -> OriginalEmailSource? {
        guard await accountGenerationsAreCurrent(
            html: accountGeneration,
            rendered: renderedAccountGeneration
        ) else {
            return nil
        }
        guard let canonicalContent = await canonicalContentLoader.loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: true,
            expectedAccountGeneration: accountGeneration
        ) else {
            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "OriginalEmailSourceLoader message \(messageId): no source",
                category: .ui
            )
            return nil
        }
        guard await accountGenerationsAreCurrent(
            html: accountGeneration,
            rendered: renderedAccountGeneration
        ) else {
            return nil
        }

        if let canonicalHTML = canonicalContent.html,
           let html = await renderedMessageCache.cacheAwareWrappedOriginalHTML(
                messageId: messageId,
                sourceSignature: canonicalContent.sourceSignature,
                variantKey: originalHTMLVariantKey(
                    content: canonicalContent,
                    senderEmail: senderEmail,
                    subject: subject
                ),
                expectedAccountGeneration: renderedAccountGeneration,
                producer: {
                    await self.prepareOriginalHTMLWithTelemetry(
                        canonicalHTML,
                        content: canonicalContent,
                        messageId: messageId,
                        senderEmail: senderEmail,
                        subject: subject,
                        accountGeneration: accountGeneration
                    )
                }
           ),
           await accountGenerationsAreCurrent(
               html: accountGeneration,
               rendered: renderedAccountGeneration
           ) {
            let source = OriginalEmailSource(
                presentation: .html,
                html: html,
                plainText: nil,
                sourceKind: canonicalContent.sourceKind,
                sourceLocation: canonicalContent.sourceLocation,
                sourceSignature: canonicalContent.sourceSignature,
                hasHTMLSource: true
            )
            log(source, messageId: messageId)
            return source
        }

        if canonicalContent.hasHTMLSource,
           let fallbackSource = await loadFallbackHTMLSource(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject,
            accountGeneration: accountGeneration
           ),
           await accountGenerationsAreCurrent(
               html: accountGeneration,
               rendered: renderedAccountGeneration
           ) {
            log(fallbackSource, messageId: messageId)
            return fallbackSource
        }

        if canonicalContent.hasHTMLSource,
           await accountGenerationsAreCurrent(
               html: accountGeneration,
               rendered: renderedAccountGeneration
           ),
           let recoveredContent = await canonicalContentLoader.recoverCanonicalEmailContent(
            messageId: messageId,
            bodyText: bodyText,
            expectedAccountGeneration: accountGeneration
           ),
           await accountGenerationsAreCurrent(
               html: accountGeneration,
               rendered: renderedAccountGeneration
           ),
           let recoveredHTML = recoveredContent.html,
           recoveredContent.sourceSignature != canonicalContent.sourceSignature,
           let html = await renderedMessageCache.cacheAwareWrappedOriginalHTML(
                messageId: messageId,
                sourceSignature: recoveredContent.sourceSignature,
                variantKey: originalHTMLVariantKey(
                    content: recoveredContent,
                    senderEmail: senderEmail,
                    subject: subject
                ),
                expectedAccountGeneration: renderedAccountGeneration,
                producer: {
                    await self.prepareOriginalHTMLWithTelemetry(
                        recoveredHTML,
                        content: recoveredContent,
                        messageId: messageId,
                        senderEmail: senderEmail,
                        subject: subject,
                        accountGeneration: accountGeneration
                    )
                }
           ),
           await accountGenerationsAreCurrent(
               html: accountGeneration,
               rendered: renderedAccountGeneration
           ) {
            let source = OriginalEmailSource(
                presentation: .html,
                html: html,
                plainText: nil,
                sourceKind: recoveredContent.sourceKind,
                sourceLocation: recoveredContent.sourceLocation,
                sourceSignature: recoveredContent.sourceSignature,
                hasHTMLSource: true
            )
            log(source, messageId: messageId)
            return source
        }

        guard await accountGenerationsAreCurrent(
                  html: accountGeneration,
                  rendered: renderedAccountGeneration
              ),
              let plainText = canonicalContent.plainText else {
            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "OriginalEmailSourceLoader message \(messageId): HTML source existed but could not be prepared; not falling back to plain text",
                category: .ui
            )
            return nil
        }

        if canonicalContent.hasHTMLSource {
            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "OriginalEmailSourceLoader message \(messageId): HTML source existed but could not be prepared; using plain text fallback",
                category: .ui
            )
        }

        let source = OriginalEmailSource(
            presentation: .nativePlainText,
            html: nil,
            plainText: plainText,
            sourceKind: .plainText,
            sourceLocation: .plainText,
            sourceSignature: canonicalContent.sourceSignature,
            hasHTMLSource: canonicalContent.hasHTMLSource
        )
        log(source, messageId: messageId)
        return source
    }

    /// Prepares and caches the original-email HTML ahead of a full-view open so the tap becomes an
    /// instant `RenderedMessageCache` hit instead of a cold, multi-second prepare.
    ///
    /// Uses only locally available canonical content (`allowRecovery: false`) so warming never issues
    /// Gmail network recovery while a chat thread scrolls. It writes the exact same
    /// `wrappedOriginalHTML` cache entry (same variant key and producer) that
    /// `loadOriginalEmailSourceToCompletion` reads when the prepared HTML is cacheable, so a
    /// subsequent open returns immediately without pinning first-pass remote-image rewrites.
    /// Safe to call repeatedly and from background priority; the rendered cache dedups concurrent
    /// producers for the same key.
    ///
    /// Returns the display-ready wrapped HTML (and its canonical source signature) when local content
    /// is available, so callers can pre-render the exact HTML the full-view reader will show. Returns
    /// `nil` when there is no locally available HTML source or the row scrolled away mid-warm.
    @discardableResult
    func warmOriginalEmailSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?
    ) async -> WarmedOriginalEmailHTML? {
        guard let accountGeneration = htmlContentLoader.captureAccountGeneration(),
              let renderedAccountGeneration = await renderedMessageCache.captureAccountGeneration(),
              await accountGenerationsAreCurrent(
                  html: accountGeneration,
                  rendered: renderedAccountGeneration
              ) else {
            return nil
        }
        guard let canonicalContent = await canonicalContentLoader.loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: false,
            expectedAccountGeneration: accountGeneration
        ),
              let canonicalHTML = canonicalContent.html,
              await accountGenerationsAreCurrent(
                  html: accountGeneration,
                  rendered: renderedAccountGeneration
              ) else {
            return nil
        }

        // Skip the expensive prepare if the caller (e.g. a chat row) has already scrolled away.
        guard !Task.isCancelled else {
            return nil
        }

        guard let html = await renderedMessageCache.cacheAwareWrappedOriginalHTML(
            messageId: messageId,
            sourceSignature: canonicalContent.sourceSignature,
            variantKey: originalHTMLVariantKey(
                content: canonicalContent,
                senderEmail: senderEmail,
                subject: subject
            ),
            expectedAccountGeneration: renderedAccountGeneration,
            producer: {
                await self.prepareOriginalHTMLWithTelemetry(
                    canonicalHTML,
                    content: canonicalContent,
                    messageId: messageId,
                    senderEmail: senderEmail,
                    subject: subject,
                    accountGeneration: accountGeneration
                )
            }
        ), await accountGenerationsAreCurrent(
            html: accountGeneration,
            rendered: renderedAccountGeneration
        ) else {
            return nil
        }

        return WarmedOriginalEmailHTML(
            html: html,
            sourceSignature: canonicalContent.sourceSignature,
            sourceKind: canonicalContent.sourceKind,
            sourceLocation: canonicalContent.sourceLocation,
            hasHTMLSource: canonicalContent.hasHTMLSource
        )
    }

    func invalidateWarmedOriginalEmailSource(messageId: String) async {
        await renderedMessageCache.invalidate(messageId: messageId, reason: .explicit)
    }

    func currentHTMLSourceSignature(
        messageId: String,
        bodyStorageURI: String?
    ) -> String? {
        canonicalContentLoader.currentHTMLSourceSignature(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI
        )
    }

    private func prepareOriginalHTMLWithTelemetry(
        _ canonicalHTML: String,
        content: CanonicalEmailContent,
        messageId: String,
        senderEmail: String?,
        subject: String?,
        accountGeneration: HTMLContentAccountGeneration
    ) async -> PreparedOriginalHTML? {
        let source = telemetrySourceName(sourceLocation: content.sourceLocation)
        let start = CFAbsoluteTimeGetCurrent()
        OriginalEmailTelemetry.log(
            event: "original_email_sanitize_started",
            messageId: messageId,
            source: source,
            detail: "sourceLocation=\(content.sourceLocation.rawValue)"
        )

        let prepared = await htmlContentLoader.prepareOriginalHTMLForCaching(
            fromCanonicalHTML: canonicalHTML,
            messageId: messageId,
            sourceLocation: content.sourceLocation,
            plainText: content.plainText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: false,
            expectedAccountGeneration: accountGeneration
        )

        OriginalEmailTelemetry.log(
            event: prepared == nil ? "original_email_sanitize_failed" : "original_email_sanitize_completed",
            messageId: messageId,
            source: source,
            duration: CFAbsoluteTimeGetCurrent() - start,
            detail: prepared == nil ? "failure_reason=prepare_original_html_failed" : nil
        )
        return prepared
    }

    private func loadFallbackHTMLSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        accountGeneration: HTMLContentAccountGeneration
    ) async -> OriginalEmailSource? {
        let fallback = await htmlContentLoader.loadContentWithTimeout(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: false,
            cleanupMode: .none,
            displayPurpose: .original,
            originalHTMLPreference: .preferHTML,
            timeout: 5.0,
            expectedAccountGeneration: accountGeneration
        )

        guard fallback.presentation == .html,
              let html = fallback.html,
              let sourceLocation = canonicalSourceLocation(for: fallback.source) else {
            return nil
        }

        let sourceKind: CanonicalEmailSourceKind = fallback.source == .recovered ? .recoveredHTML : .html
        return OriginalEmailSource(
            presentation: .html,
            html: html,
            plainText: nil,
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            sourceSignature: fallback.sourceSignature ?? "\(sourceKind.rawValue):fallback",
            hasHTMLSource: true
        )
    }

    private func canonicalSourceLocation(
        for source: HTMLLoadResult.HTMLLoadSource
    ) -> CanonicalEmailSourceLocation? {
        switch source {
        case .messageId:
            return .messageFile
        case .storageURI:
            return .storageURI
        case .rawSourceHTML:
            return .rawSourceHTML
        case .recovered:
            return .recoveredHTML
        case .qualityFallback, .plainTextFallback, .notFound:
            return nil
        }
    }

    private func accountGenerationsAreCurrent(
        html: HTMLContentAccountGeneration,
        rendered: RenderedMessageCacheAccountGeneration
    ) async -> Bool {
        guard htmlContentLoader.isAccountGenerationCurrent(html) else {
            return false
        }
        return await renderedMessageCache.isAccountGenerationCurrent(rendered)
    }

    private func log(_ source: OriginalEmailSource, messageId: String) {
        Log.diagnostic(
            .htmlPreview,
            level: .info,
            "OriginalEmailSourceLoader message \(messageId): sourceKind=\(source.sourceKind.rawValue) sourceLocation=\(source.sourceLocation.rawValue) presentation=\(source.presentation.rawValue)",
            category: .ui
        )
    }

    private func originalHTMLVariantKey(
        content: CanonicalEmailContent,
        senderEmail: String?,
        subject: String?
    ) -> RenderedMessageVariantKey {
        RenderedMessageVariantKey([
            "wrapped-original-html-v1",
            "sourceLocation:\(content.sourceLocation.rawValue)",
            "plainText:\(Self.fingerprint(for: content.plainText))",
            "sender:\(Self.fingerprint(for: senderEmail))",
            "subject:\(Self.fingerprint(for: subject))"
        ].joined(separator: "|"))
    }

    private static func fingerprint(for text: String?) -> String {
        guard let text = text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return "nil"
        }

        return SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func telemetrySourceName(for source: OriginalEmailSource) -> String {
        telemetrySourceName(sourceLocation: source.sourceLocation)
    }

    private func telemetrySourceName(sourceLocation: CanonicalEmailSourceLocation) -> String {
        switch sourceLocation {
        case .messageFile, .storageURI:
            return "decoded_cache"
        case .rawSourceHTML:
            return "raw_cache"
        case .recoveredHTML:
            return "provider_fetch"
        case .plainText:
            return "plain_text_fallback"
        }
    }
}
