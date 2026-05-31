import CryptoKit
import Foundation

struct EmailPreviewPipelineRequest: Sendable {
    let messageId: String
    let bodyStorageURI: String?
    let bodyText: String?
    let cleanedSnippet: String?
    let senderName: String?
    let senderEmail: String?
    let subject: String?
    let isNewsletter: Bool
    let isForwardedEmail: Bool
    let cleanupMode: HTMLContentCleanupMode
    let isDarkMode: Bool
}

enum NativePreviewCardRoute: Equatable, Sendable {
    case newsletter
    case transactional
}

struct HTMLPreviewPayload: Equatable, Sendable {
    let html: String
    let previewCacheKey: String
}

enum EmailPreviewRenderModel: Equatable, Sendable {
    case calendarInvite(CalendarInvitePreviewModel)
    case newsletter(NewsletterPreviewModel)
    case transactional(TransactionalPreviewModel)
    case netlifyDeploy(NetlifyDeployPreviewModel)
    case html(HTMLPreviewPayload)
}

final class EmailPreviewPipeline: @unchecked Sendable {
    static let shared = EmailPreviewPipeline()

    private let previewSourceLoader: any EmailPreviewSourceLoading
    private let htmlContentLoader: HTMLContentLoader
    private let calendarInvitePreviewBuilder: CalendarInvitePreviewBuilder
    private let newsletterPreviewBuilder: NewsletterPreviewBuilder
    private let transactionalPreviewBuilder: TransactionalPreviewBuilder
    private let netlifyDeployPreviewBuilder: NetlifyDeployPreviewBuilder
    private let renderedMessageCache: RenderedMessageCache

    init(
        previewSourceLoader: any EmailPreviewSourceLoading = EmailPreviewSourceLoader.shared,
        htmlContentLoader: HTMLContentLoader = .shared,
        calendarInvitePreviewBuilder: CalendarInvitePreviewBuilder = CalendarInvitePreviewBuilder(),
        newsletterPreviewBuilder: NewsletterPreviewBuilder = NewsletterPreviewBuilder(),
        transactionalPreviewBuilder: TransactionalPreviewBuilder = TransactionalPreviewBuilder(),
        netlifyDeployPreviewBuilder: NetlifyDeployPreviewBuilder = NetlifyDeployPreviewBuilder(),
        renderedMessageCache: RenderedMessageCache = .shared
    ) {
        self.previewSourceLoader = previewSourceLoader
        self.htmlContentLoader = htmlContentLoader
        self.calendarInvitePreviewBuilder = calendarInvitePreviewBuilder
        self.newsletterPreviewBuilder = newsletterPreviewBuilder
        self.transactionalPreviewBuilder = transactionalPreviewBuilder
        self.netlifyDeployPreviewBuilder = netlifyDeployPreviewBuilder
        self.renderedMessageCache = renderedMessageCache
    }

    func loadPreview(request: EmailPreviewPipelineRequest) async -> EmailPreviewRenderModel? {
        guard let previewSource = await previewSourceLoader.loadPreviewSource(
            messageId: request.messageId,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            senderEmail: request.senderEmail,
            subject: request.subject,
            allowRecovery: true
        ),
              previewSource.canonicalHTML != nil else {
            if let fallbackPreview = await loadFallbackHTMLPreview(request: request) {
                return fallbackPreview
            }

            Log.diagnostic(
                .htmlPreview,
                level: .info,
                "EmailPreviewPipeline message \(request.messageId): no HTML preview source",
                category: .ui
            )
            return nil
        }

        return await renderedMessageCache.previewRenderModel(
            messageId: request.messageId,
            sourceSignature: previewSource.sourceSignature,
            variantKey: previewRenderVariantKey(for: request)
        ) {
            await self.buildPreview(previewSource: previewSource, request: request)
        }
    }

    private func buildPreview(
        previewSource: EmailPreviewSource,
        request: EmailPreviewPipelineRequest
    ) async -> EmailPreviewRenderModel? {
        guard let canonicalHTML = previewSource.canonicalHTML else {
            return await loadFallbackHTMLPreview(request: request)
        }

        let classification = previewSource.classification
        Log.diagnostic(
            .htmlPreview,
            level: .info,
            "EmailPreviewPipeline message \(request.messageId): sourceKind=\(previewSource.sourceKind.rawValue) \(classification.diagnosticSummary)",
            category: .ui
        )

        if !request.isForwardedEmail,
           let model = calendarInvitePreviewBuilder.buildPreview(
            canonicalHTML: canonicalHTML,
            bodyText: previewSource.plainText,
            cleanedSnippet: request.cleanedSnippet,
            senderName: request.senderName,
            senderEmail: request.senderEmail,
            subject: request.subject
           ) {
            return .calendarInvite(model)
        }

        if !request.isForwardedEmail,
           let model = netlifyDeployPreviewBuilder.buildPreview(
            canonicalHTML: canonicalHTML,
            senderEmail: request.senderEmail,
            subject: request.subject
           ) {
            return .netlifyDeploy(model)
        }

        for route in Self.nativePreviewCardRoutes(
            isNewsletter: request.isNewsletter,
            isForwardedEmail: request.isForwardedEmail,
            classificationKind: classification.kind
        ) {
            switch route {
            case .newsletter:
                if let model = newsletterPreviewBuilder.buildPreview(
                    source: previewSource,
                    cleanedSnippet: request.cleanedSnippet,
                    senderName: request.senderName,
                    senderEmail: request.senderEmail,
                    subject: request.subject
                ) {
                    return .newsletter(model)
                }

                Log.diagnostic(
                    .htmlPreview,
                    level: .info,
                    "EmailPreviewPipeline newsletter fallback for message \(request.messageId): preview model unavailable",
                    category: .ui
                )
            case .transactional:
                if let model = transactionalPreviewBuilder.buildPreview(
                    source: previewSource,
                    cleanedSnippet: request.cleanedSnippet,
                    senderName: request.senderName,
                    senderEmail: request.senderEmail,
                    subject: request.subject
                ) {
                    return .transactional(model)
                }

                Log.diagnostic(
                    .htmlPreview,
                    level: .info,
                    "EmailPreviewPipeline transactional fallback for message \(request.messageId): preview model unavailable",
                    category: .ui
                )
            }
        }

        guard let payload = await renderedMessageCache.wrappedPreviewHTML(
            messageId: request.messageId,
            sourceSignature: previewSource.sourceSignature,
            variantKey: wrappedPreviewHTMLVariantKey(
                request: request,
                previewSource: previewSource
            ),
            producer: {
            guard let previewHTML = await self.htmlContentLoader.preparePreviewHTML(
                fromCanonicalHTML: canonicalHTML,
                messageId: request.messageId,
                bodyText: previewSource.plainText,
                senderEmail: request.senderEmail,
                subject: request.subject,
                isDarkMode: request.isDarkMode,
                cleanupMode: request.cleanupMode
            ) else {
                return nil
            }

            return HTMLPreviewPayload(
                html: previewHTML,
                previewCacheKey: Self.makePreviewHTMLCacheKey(
                    messageId: request.messageId,
                    sourceSignature: previewSource.sourceSignature,
                    isDarkMode: request.isDarkMode,
                    cleanupMode: request.cleanupMode
                )
            )
        }) else {
            return await loadFallbackHTMLPreview(request: request)
        }

        return .html(payload)
    }

    static func makePreviewHTMLCacheKey(
        messageId: String,
        sourceSignature: String,
        isDarkMode: Bool,
        cleanupMode: HTMLContentCleanupMode
    ) -> String {
        "\(messageId)|\(sourceSignature)|mode:html-preview|dark:\(isDarkMode)|cleanup:\(cleanupMode.rawValue)"
    }

    static func shouldUseTransactionalPreviewCard(isForwardedEmail: Bool) -> Bool {
        !isForwardedEmail
    }

    static func nativePreviewCardRoutes(
        isNewsletter: Bool,
        isForwardedEmail: Bool,
        classificationKind: EmailPreviewKind
    ) -> [NativePreviewCardRoute] {
        var routes: [NativePreviewCardRoute] = []

        if classificationKind == .transactional,
           shouldUseTransactionalPreviewCard(isForwardedEmail: isForwardedEmail) {
            routes.append(.transactional)
        }

        if !isForwardedEmail,
           classificationKind == .newsletter || isNewsletter {
            routes.append(.newsletter)
        }

        return routes
    }

    private func loadFallbackHTMLPreview(
        request: EmailPreviewPipelineRequest
    ) async -> EmailPreviewRenderModel? {
        let fallback = await htmlContentLoader.loadContentWithTimeout(
            messageId: request.messageId,
            bodyStorageURI: request.bodyStorageURI,
            bodyText: request.bodyText,
            senderEmail: request.senderEmail,
            subject: request.subject,
            isDarkMode: request.isDarkMode,
            cleanupMode: request.cleanupMode,
            displayPurpose: .preview,
            timeout: 5.0
        )

        guard fallback.presentation == .html,
              let html = fallback.html else {
            return nil
        }

        Log.diagnostic(
            .htmlPreview,
            level: .info,
            "EmailPreviewPipeline message \(request.messageId): using fallback preview source=\(fallback.source)",
            category: .ui
        )

        return .html(
            HTMLPreviewPayload(
                html: html,
                previewCacheKey: Self.makePreviewHTMLCacheKey(
                    messageId: request.messageId,
                    sourceSignature: fallback.sourceSignature ?? "plainText:unknown",
                    isDarkMode: request.isDarkMode,
                    cleanupMode: request.cleanupMode
                )
            )
        )
    }

    private func previewRenderVariantKey(for request: EmailPreviewPipelineRequest) -> RenderedMessageVariantKey {
        RenderedMessageVariantKey([
            "preview-render-v1",
            "body:\(Self.fingerprint(for: request.bodyText))",
            "snippet:\(Self.fingerprint(for: request.cleanedSnippet))",
            "senderName:\(Self.fingerprint(for: request.senderName))",
            "senderEmail:\(Self.fingerprint(for: request.senderEmail))",
            "subject:\(Self.fingerprint(for: request.subject))",
            "newsletter:\(request.isNewsletter)",
            "forwarded:\(request.isForwardedEmail)",
            "cleanup:\(request.cleanupMode.rawValue)",
            "dark:\(request.isDarkMode)"
        ].joined(separator: "|"))
    }

    private func wrappedPreviewHTMLVariantKey(
        request: EmailPreviewPipelineRequest,
        previewSource: EmailPreviewSource
    ) -> RenderedMessageVariantKey {
        RenderedMessageVariantKey([
            "wrapped-preview-html-v1",
            "body:\(Self.fingerprint(for: previewSource.plainText))",
            "senderEmail:\(Self.fingerprint(for: request.senderEmail))",
            "subject:\(Self.fingerprint(for: request.subject))",
            "cleanup:\(request.cleanupMode.rawValue)",
            "dark:\(request.isDarkMode)"
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
