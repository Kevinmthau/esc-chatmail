import CryptoKit
import Foundation

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

protocol OriginalEmailSourceLoading: Sendable {
    func loadOriginalEmailSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        timeout: TimeInterval
    ) async -> OriginalEmailSource?
}

final class OriginalEmailSourceLoader: OriginalEmailSourceLoading, @unchecked Sendable {
    static let shared = OriginalEmailSourceLoader()

    private let canonicalContentLoader: any CanonicalEmailContentLoading
    private let htmlContentLoader: HTMLContentLoader
    private let renderedMessageCache: RenderedMessageCache

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
                subject: subject
            )
        }
        return result ?? nil
    }

    func loadOriginalEmailSourceToCompletion(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?
    ) async -> OriginalEmailSource? {
        guard let canonicalContent = await canonicalContentLoader.loadCanonicalEmailContent(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            allowRecovery: true
        ) else {
            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "OriginalEmailSourceLoader message \(messageId): no source",
                category: .ui
            )
            return nil
        }

        if let canonicalHTML = canonicalContent.html,
           let html = await renderedMessageCache.wrappedOriginalHTML(
                messageId: messageId,
                sourceSignature: canonicalContent.sourceSignature,
                variantKey: originalHTMLVariantKey(
                    content: canonicalContent,
                    senderEmail: senderEmail,
                    subject: subject
                ),
                producer: {
                    await self.htmlContentLoader.prepareOriginalHTML(
                        fromCanonicalHTML: canonicalHTML,
                        messageId: messageId,
                        sourceLocation: canonicalContent.sourceLocation,
                        plainText: canonicalContent.plainText,
                        senderEmail: senderEmail,
                        subject: subject,
                        isDarkMode: false
                    )
                }
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
            subject: subject
           ) {
            log(fallbackSource, messageId: messageId)
            return fallbackSource
        }

        if canonicalContent.hasHTMLSource,
           let recoveredContent = await canonicalContentLoader.recoverCanonicalEmailContent(
            messageId: messageId,
            bodyText: bodyText
           ),
           let recoveredHTML = recoveredContent.html,
           recoveredContent.sourceSignature != canonicalContent.sourceSignature,
           let html = await renderedMessageCache.wrappedOriginalHTML(
                messageId: messageId,
                sourceSignature: recoveredContent.sourceSignature,
                variantKey: originalHTMLVariantKey(
                    content: recoveredContent,
                    senderEmail: senderEmail,
                    subject: subject
                ),
                producer: {
                    await self.htmlContentLoader.prepareOriginalHTML(
                        fromCanonicalHTML: recoveredHTML,
                        messageId: messageId,
                        sourceLocation: recoveredContent.sourceLocation,
                        plainText: recoveredContent.plainText,
                        senderEmail: senderEmail,
                        subject: subject,
                        isDarkMode: false
                    )
                }
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

        guard let plainText = canonicalContent.plainText else {
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

    private func loadFallbackHTMLSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?
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
            timeout: 5.0
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
}
