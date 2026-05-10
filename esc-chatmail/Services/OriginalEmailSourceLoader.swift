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
        isDarkMode: Bool,
        timeout: TimeInterval
    ) async -> OriginalEmailSource?
}

final class OriginalEmailSourceLoader: OriginalEmailSourceLoading, @unchecked Sendable {
    static let shared = OriginalEmailSourceLoader()

    private let canonicalContentLoader: any CanonicalEmailContentLoading
    private let htmlContentLoader: HTMLContentLoader

    init(
        canonicalContentLoader: any CanonicalEmailContentLoading = CanonicalEmailContentLoader.shared,
        htmlContentLoader: HTMLContentLoader = .shared
    ) {
        self.canonicalContentLoader = canonicalContentLoader
        self.htmlContentLoader = htmlContentLoader
    }

    func loadOriginalEmailSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        isDarkMode: Bool,
        timeout: TimeInterval = 5.0
    ) async -> OriginalEmailSource? {
        await withTaskGroup(of: OriginalEmailSource?.self) { group in
            group.addTask {
                await self.loadOriginalEmailSourceWithoutTimeout(
                    messageId: messageId,
                    bodyStorageURI: bodyStorageURI,
                    bodyText: bodyText,
                    senderEmail: senderEmail,
                    subject: subject,
                    isDarkMode: isDarkMode
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            for await result in group {
                group.cancelAll()
                return result
            }

            return nil
        }
    }

    private func loadOriginalEmailSourceWithoutTimeout(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        isDarkMode: Bool
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
           let html = await htmlContentLoader.prepareOriginalHTML(
            fromCanonicalHTML: canonicalHTML,
            messageId: messageId,
            sourceLocation: canonicalContent.sourceLocation,
            plainText: canonicalContent.plainText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode
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
            isDarkMode: isDarkMode
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
           let html = await htmlContentLoader.prepareOriginalHTML(
            fromCanonicalHTML: recoveredHTML,
            messageId: messageId,
            sourceLocation: recoveredContent.sourceLocation,
            plainText: recoveredContent.plainText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode
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
        subject: String?,
        isDarkMode: Bool
    ) async -> OriginalEmailSource? {
        let fallback = await htmlContentLoader.loadContentWithTimeout(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject,
            isDarkMode: isDarkMode,
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
}
