import CryptoKit
import Foundation

enum ChatBubbleTextInputKind: Sendable {
    case html
    case plainText
    case autoDetectHTML
}

struct ChatBubbleTextProcessorOptions: Sendable {
    let inputKind: ChatBubbleTextInputKind
    let sanitizeRawEmailSource: Bool
    let decodeHTMLEntities: Bool
    let formatSignOffLineBreaks: Bool
    let classifyRichContent: Bool

    init(
        inputKind: ChatBubbleTextInputKind,
        sanitizeRawEmailSource: Bool = true,
        decodeHTMLEntities: Bool = true,
        formatSignOffLineBreaks: Bool = true,
        classifyRichContent: Bool = false
    ) {
        self.inputKind = inputKind
        self.sanitizeRawEmailSource = sanitizeRawEmailSource
        self.decodeHTMLEntities = decodeHTMLEntities
        self.formatSignOffLineBreaks = formatSignOffLineBreaks
        self.classifyRichContent = classifyRichContent
    }
}

struct ChatBubbleTextProcessingResult: Sendable {
    let mainText: String?
    let quotedParts: [QuotedPart]
    let hasRichContent: Bool

    init(mainText: String?, quotedParts: [QuotedPart] = [], hasRichContent: Bool = false) {
        self.mainText = mainText
        self.quotedParts = quotedParts
        self.hasRichContent = hasRichContent
    }
}

enum ChatBubbleTextProcessor {
    // Detects genuine HTML tags while avoiding false positives on expressions like `5 < 10 > 3`.
    private static let htmlTagPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "<[a-zA-Z][a-zA-Z0-9]*(?:\\s[^>]*)?>|</[a-zA-Z][a-zA-Z0-9]*>|<[a-zA-Z][a-zA-Z0-9]*(?:\\s[^>\\n]*)?$",
            options: []
        )
    }()

    static func process(
        content: String?,
        options: ChatBubbleTextProcessorOptions
    ) -> ChatBubbleTextProcessingResult {
        guard let content, !content.isEmpty else {
            return ChatBubbleTextProcessingResult(mainText: nil, quotedParts: [], hasRichContent: false)
        }

        let inputKind = resolvedInputKind(for: content, requestedKind: options.inputKind)
        if inputKind == .html {
            return processHTML(
                content,
                decodeHTMLEntities: options.decodeHTMLEntities,
                formatSignOffLineBreaks: options.formatSignOffLineBreaks,
                classifyRichContent: options.classifyRichContent
            )
        }

        return processPlainText(
            content,
            sanitizeRawEmailSource: options.sanitizeRawEmailSource,
            decodeHTMLEntities: options.decodeHTMLEntities,
            formatSignOffLineBreaks: options.formatSignOffLineBreaks
        )
    }

    private static func resolvedInputKind(
        for content: String,
        requestedKind: ChatBubbleTextInputKind
    ) -> ChatBubbleTextInputKind {
        switch requestedKind {
        case .autoDetectHTML:
            containsHTMLTags(content) ? .html : .plainText
        case .html, .plainText:
            requestedKind
        }
    }

    static func htmlCompatibilityFallback(
        from html: String?,
        classifyRichContent: Bool
    ) -> ChatBubbleTextProcessingResult {
        process(
            content: html,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .html,
                sanitizeRawEmailSource: false,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: classifyRichContent
            )
        )
    }

    static func plainTextOnlyFallback(
        from text: String?,
        sanitizeRawEmailSource: Bool = true,
        decodeHTMLEntities: Bool = true
    ) -> ChatBubbleTextProcessingResult {
        process(
            content: text,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .plainText,
                sanitizeRawEmailSource: sanitizeRawEmailSource,
                decodeHTMLEntities: decodeHTMLEntities,
                formatSignOffLineBreaks: true,
                classifyRichContent: false
            )
        )
    }

    static func legacyAutoDetectedFallback(
        from text: String?,
        sanitizeRawEmailSource: Bool = true,
        classifyRichContent: Bool
    ) -> ChatBubbleTextProcessingResult {
        process(
            content: text,
            options: ChatBubbleTextProcessorOptions(
                inputKind: .autoDetectHTML,
                sanitizeRawEmailSource: sanitizeRawEmailSource,
                decodeHTMLEntities: true,
                formatSignOffLineBreaks: true,
                classifyRichContent: classifyRichContent
            )
        )
    }

    private static func processHTML(
        _ html: String,
        decodeHTMLEntities: Bool,
        formatSignOffLineBreaks: Bool,
        classifyRichContent: Bool
    ) -> ChatBubbleTextProcessingResult {
        // Strip quoted/signature content from HTML first. If that pass removes too much
        // (e.g., transactional templates), fall back to quote-only cleanup or original HTML.
        let cleanup = ProcessedTextCache.cleanedHTMLForProcessing(html)

        var plainText = ProcessedTextCache.extractPlainTextFromHTML(
            from: cleanup.html,
            decodeHTMLEntities: decodeHTMLEntities,
            formatSignOffLineBreaks: formatSignOffLineBreaks,
            applyPlainTextQuoteRemoval: cleanup.applyPlainTextQuoteRemoval
        )

        if plainText == nil {
            plainText = ProcessedTextCache.extractPlainTextFromHTML(
                from: html,
                decodeHTMLEntities: decodeHTMLEntities,
                formatSignOffLineBreaks: formatSignOffLineBreaks,
                applyPlainTextQuoteRemoval: true
            )
        }

        let hasRichContent = classifyRichContent ? ProcessedTextCache.hasGenuineRichContent(cleanup.html) : false
        return ChatBubbleTextProcessingResult(
            mainText: plainText,
            quotedParts: [],
            hasRichContent: hasRichContent
        )
    }

    private static func processPlainText(
        _ text: String,
        sanitizeRawEmailSource: Bool,
        decodeHTMLEntities: Bool,
        formatSignOffLineBreaks: Bool
    ) -> ChatBubbleTextProcessingResult {
        // Legacy/plain-text-only fallback. Normal chat bubbles should use the
        // persisted Message.chatPreviewText and avoid this quote/signature path.
        var processed = text
        if sanitizeRawEmailSource {
            processed = RawEmailSourceSanitizer.extractDisplayText(from: processed)
        }

        if decodeHTMLEntities {
            processed = HTMLEntityDecoder.decode(processed)
        }

        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: processed)
        let extractionResult = PlainTextQuoteRemover.extractQuotes(from: unwrapped)
        let mainContent = formatSignOffLineBreaks
            ? TextProcessing.formatSignOffLineBreaks(in: extractionResult.mainContent)
            : extractionResult.mainContent
        let trimmed = mainContent.trimmingCharacters(in: .whitespacesAndNewlines)

        return ChatBubbleTextProcessingResult(
            mainText: trimmed.isEmpty ? nil : trimmed,
            quotedParts: extractionResult.quotedParts,
            hasRichContent: false
        )
    }

    fileprivate static func containsHTMLTags(_ text: String) -> Bool {
        guard let regex = htmlTagPattern else {
            return text.contains("<") && text.contains(">")
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}

fileprivate struct HTMLProcessingCleanupResult {
    let html: String
    let applyPlainTextQuoteRemoval: Bool
}

/// Thread-safe cache for processed message text content
/// Eliminates redundant HTML parsing and regex operations during scroll
/// Uses LRUCacheActor for automatic eviction management
actor ProcessedTextCache: MemoryWarningHandler {
    static let shared = ProcessedTextCache()
    // Bump to invalidate cached entries when processing logic changes.
    private static let processingVersion = "2026-05-30-chat-preview-primary-v2"
    static let chatBubblePreviewMode = "chat-bubble-preview"
    static let richContentAnalysisMode = "rich-content-analysis"

    /// Cached text content with rich content indicator and extracted quotes
    struct CachedText: Sendable {
        let plainText: String?
        let hasRichContent: Bool
        let quotedParts: [QuotedPart]

        init(
            plainText: String?,
            hasRichContent: Bool,
            quotedParts: [QuotedPart] = []
        ) {
            self.plainText = plainText
            self.hasRichContent = hasRichContent
            self.quotedParts = quotedParts
        }
    }

    private let cache: LRUCacheActor<String, CachedText>
    private var cacheKeysByMessageID: [String: Set<String>] = [:]
    private var cacheKeyTrackingVersion: UInt64 = 0
    private var inFlightTrackedCacheWriteCount = 0

    /// Track active prefetch task to prevent unbounded task accumulation
    private var activePrefetchTask: Task<Void, Never>?

    /// Track task identity to prevent cancelled tasks from clearing newer task references
    private var activePrefetchTaskId: UUID?

    /// Maximum number of messages to process in a single prefetch batch
    private let maxPrefetchBatchSize = 20

    /// Observes memory warnings to clear cache under pressure
    private let memoryObserver = MemoryWarningObserver()

    init() {
        self.cache = LRUCacheActor(config: CacheConfiguration(
            maxItems: CacheConfig.textCacheSize,
            maxMemoryBytes: CacheConfig.textCacheMaxBytes,
            ttlSeconds: nil,
            evictionPolicy: .lru
        ))
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.memoryObserver.start(handler: self)
        }
    }

    func handleMemoryWarning() async {
        await cache.clear()
        cacheKeysByMessageID.removeAll()
        cacheKeyTrackingVersion &+= 1
        Log.info("ProcessedTextCache cleared due to memory warning", category: .coreData)
    }

    /// Estimates memory size of a cached text entry
    private static func estimateSize(_ plainText: String?, _ hasRichContent: Bool, _ quotedParts: [QuotedPart] = []) -> Int {
        // String size: UTF-8 bytes + some overhead
        let textSize = (plainText?.utf8.count ?? 0)
        // QuotedPart size: String header (16 bytes) + String data + Optional<String> (1 byte + 16 if present) + Int (8 bytes) + alignment padding
        // Estimated 56 bytes per QuotedPart struct overhead
        let quotedSize = quotedParts.reduce(0) { sum, part in
            sum + part.text.utf8.count + (part.attribution?.utf8.count ?? 0) + 56
        }
        // Bool size + struct overhead
        let overheadSize = 24
        return textSize + quotedSize + overheadSize
    }

    private static func cacheKey(for messageId: String) -> String {
        "\(processingVersion)|\(messageId)"
    }

    private static func cacheKey(
        for messageId: String,
        sourceSignature: String,
        previewMode: String
    ) -> String {
        "\(processingVersion)|\(messageId)|source:\(sourceSignature)|mode:\(previewMode)"
    }

    func get(messageId: String) async -> (plainText: String?, hasRichContent: Bool, quotedParts: [QuotedPart])? {
        guard let entry = await cache.get(Self.cacheKey(for: messageId)) else { return nil }
        return (entry.plainText, entry.hasRichContent, entry.quotedParts)
    }

    func get(
        messageId: String,
        sourceSignature: String,
        previewMode: String
    ) async -> (
        plainText: String?,
        hasRichContent: Bool,
        quotedParts: [QuotedPart]
    )? {
        let key = Self.cacheKey(
            for: messageId,
            sourceSignature: sourceSignature,
            previewMode: previewMode
        )
        guard let entry = await cache.get(key) else { return nil }
        return (
            entry.plainText,
            entry.hasRichContent,
            entry.quotedParts
        )
    }

    func set(
        messageId: String,
        plainText: String?,
        hasRichContent: Bool,
        quotedParts: [QuotedPart] = []
    ) async {
        let size = Self.estimateSize(plainText, hasRichContent, quotedParts)
        let key = Self.cacheKey(for: messageId)
        beginTrackedCacheWrite(key, for: messageId)
        await cache.set(
            key,
            value: CachedText(
                plainText: plainText,
                hasRichContent: hasRichContent,
                quotedParts: quotedParts
            ),
            sizeBytes: size
        )
        finishTrackedCacheWrite()
        await pruneTrackedCacheKeys()
    }

    func set(
        messageId: String,
        sourceSignature: String,
        previewMode: String,
        plainText: String?,
        hasRichContent: Bool,
        quotedParts: [QuotedPart] = []
    ) async {
        let size = Self.estimateSize(plainText, hasRichContent, quotedParts)
        let key = Self.cacheKey(
            for: messageId,
            sourceSignature: sourceSignature,
            previewMode: previewMode
        )
        beginTrackedCacheWrite(key, for: messageId)
        await cache.set(
            key,
            value: CachedText(
                plainText: plainText,
                hasRichContent: hasRichContent,
                quotedParts: quotedParts
            ),
            sizeBytes: size
        )
        finishTrackedCacheWrite()
        await pruneTrackedCacheKeys()
    }

    /// Prefetches compatibility fallback text for old messages without chatPreviewText.
    func prefetch(messageIds: [String]) async {
        // Filter out already cached messages
        var uncachedMessages: [(messageId: String, sourceSignature: String)] = []
        let signatureHandler = HTMLContentHandler.shared
        for messageId in messageIds {
            let sourceSignature = Self.contentSourceSignature(
                messageId: messageId,
                bodyStorageURI: nil,
                bodyText: nil,
                handler: signatureHandler
            )
            let key = Self.cacheKey(
                for: messageId,
                sourceSignature: sourceSignature,
                previewMode: Self.chatBubblePreviewMode
            )
            if await !cache.contains(key) {
                uncachedMessages.append((messageId, sourceSignature))
            }
        }
        guard !uncachedMessages.isEmpty else { return }

        // Limit batch size to prevent processing too many at once
        let messagesToProcess = Array(uncachedMessages.prefix(maxPrefetchBatchSize))

        // Cancel any existing prefetch task to prevent accumulation during rapid scroll
        activePrefetchTask?.cancel()

        // Generate unique ID for this task to prevent race conditions on cleanup
        let taskId = UUID()
        activePrefetchTaskId = taskId

        // Track the new prefetch task
        activePrefetchTask = Task.detached(priority: .utility) { [weak self, messagesToProcess, taskId] in
            let handler = HTMLContentHandler.shared

            for (messageId, sourceSignature) in messagesToProcess {
                // Check for cancellation between messages
                guard !Task.isCancelled else { break }

                let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

                // Check again before cache write to prevent cancelled tasks from writing stale data
                guard !Task.isCancelled else { break }

                await self?.set(
                    messageId: messageId,
                    sourceSignature: sourceSignature,
                    previewMode: ProcessedTextCache.chatBubblePreviewMode,
                    plainText: result.plainText,
                    hasRichContent: result.hasRichContent,
                    quotedParts: result.quotedParts
                )
            }

            // Clear task reference on completion, but only if this is still the active task
            // (prevents cancelled tasks from clearing a newer task's reference)
            await self?.clearPrefetchTaskIfMatches(taskId)
        }
    }

    /// Clears the prefetch task reference only if it matches the given task ID
    private func clearPrefetchTaskIfMatches(_ taskId: UUID) {
        if activePrefetchTaskId == taskId {
            activePrefetchTask = nil
            activePrefetchTaskId = nil
        }
    }

    /// Cancel any active prefetch task (call when view disappears)
    func cancelPrefetch() {
        activePrefetchTask?.cancel()
        activePrefetchTask = nil
        activePrefetchTaskId = nil
    }

    /// Process a single message - can be called from background thread
    nonisolated static func processMessage(
        messageId: String,
        bodyStorageURI: String? = nil,
        handler: HTMLContentHandler
    ) -> (plainText: String?, hasRichContent: Bool, quotedParts: [QuotedPart]) {
        let html = loadHTML(messageId: messageId, bodyStorageURI: bodyStorageURI, handler: handler)
        if let html {
            let result = ChatBubbleTextProcessor.htmlCompatibilityFallback(
                from: html,
                classifyRichContent: true
            )
            return (result.mainText, result.hasRichContent, result.quotedParts)
        }

        return (nil, false, [])
    }

    /// Classifies rich HTML without deriving chat-bubble text. Used when
    /// Message.chatPreviewText is already the visible bubble source.
    nonisolated static func classifyRichContent(
        messageId: String,
        bodyStorageURI: String? = nil,
        bodyText: String? = nil,
        handler: HTMLContentHandler
    ) -> Bool {
        guard let html = richContentHTMLCandidate(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            handler: handler
        ) else {
            return false
        }

        return hasGenuineRichContentAfterCleanup(html)
    }

    nonisolated private static func richContentHTMLCandidate(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        handler: HTMLContentHandler
    ) -> String? {
        if let html = loadHTML(messageId: messageId, bodyStorageURI: bodyStorageURI, handler: handler) {
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

    nonisolated private static func hasGenuineRichContentAfterCleanup(_ html: String) -> Bool {
        let cleanup = cleanedHTMLForProcessing(html)
        return hasGenuineRichContent(cleanup.html)
    }

    nonisolated static func contentSourceSignature(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        handler: HTMLContentHandler
    ) -> String {
        let htmlSourceSignature = handler.htmlSourceSignature(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI
        )
        if htmlSourceSignature != "missing" {
            return "html:\(htmlSourceSignature)"
        }

        if let bodyTextSignature = bodyTextSignature(for: bodyText) {
            return "body:\(bodyTextSignature)"
        }

        return "empty"
    }

    nonisolated static func fallbackContentSourceSignature(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        handler: HTMLContentHandler
    ) -> String {
        let sourceSignature = contentSourceSignature(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            handler: handler
        )
        guard sourceSignature.hasPrefix("html:"),
              let bodyTextSignature = bodyTextSignature(for: bodyText) else {
            return sourceSignature
        }

        return "\(sourceSignature)|fallback-body:\(bodyTextSignature)"
    }

    nonisolated private static func bodyTextSignature(for bodyText: String?) -> String? {
        guard let bodyText = bodyText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bodyText.isEmpty else {
            return nil
        }

        return sha256Signature(for: bodyText)
    }

    nonisolated private static func loadHTML(
        messageId: String,
        bodyStorageURI: String?,
        handler: HTMLContentHandler
    ) -> String? {
        if handler.htmlFileExists(for: messageId),
           let html = handler.loadHTML(for: messageId) {
            return html
        }

        guard let urlString = bodyStorageURI,
              let url = StorageURIResolver.resolve(urlString),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return handler.loadHTML(from: url)
    }

    nonisolated private static func sha256Signature(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    /// Determines if HTML contains genuine rich content (newsletters, receipts) vs personal email signature cruft
    /// Personal emails can have elaborate signatures (logo + headshot + 6-8 social icons + layout tables)
    /// Newsletters and marketing emails have many elements AND substantial text content
    nonisolated fileprivate static func hasGenuineRichContent(_ html: String) -> Bool {
        // Apple Mail injects "apple-rich-link" previews (tables, role="button", inline images) for regular
        // person-to-person emails that contain a URL. Treat those blocks as non-rich to avoid routing
        // personal messages into the HTML preview path.
        let htmlForAnalysis = stripAppleRichLinkPreviews(from: html)
        let lowercased = htmlForAnalysis.lowercased()

        // Always rich: video/iframe/embed/object (inline PDFs, videos, embedded content)
        if lowercased.contains("<video") || lowercased.contains("<iframe") ||
           lowercased.contains("<object") || lowercased.contains("<embed") {
            return true
        }

        // Always rich: semantic HTML5 elements indicating structured content
        if lowercased.contains("<article") || lowercased.contains("<section") ||
           lowercased.contains("<header") || lowercased.contains("<footer") ||
           lowercased.contains("<nav") {
            return true
        }

        // Count elements to distinguish signature cruft from actual rich content
        // Single-pass counting for better performance
        let (imgCount, tableCount, cidCount, linkCount) = countHTMLElements(htmlForAnalysis)

        // Newsletter indicators that imply rich content even when there are few images/tables.
        // Computed early so simple div-wrapped content can still detect transactional/newsletter patterns.
        let hasNewsletterIndicators = lowercased.contains("unsubscribe") ||
                                       lowercased.contains("view in browser") ||
                                       lowercased.contains("email preferences") ||
                                       lowercased.contains("privacy policy") ||
                                       lowercased.contains("manage preferences") ||
                                       lowercased.contains("update your preferences")

        // Early exit for simple div-wrapped text (common Gmail mobile format).
        // Most one-to-one personal emails should stay as chat bubbles even when long.
        // Only treat simple div content as rich when we detect explicit transactional/marketing signals.
        if imgCount == 0 && tableCount == 0 && cidCount == 0 && isSimpleDivWrappedText(htmlForAnalysis, lowercased: lowercased) {
            let textContent = approximateTextContent(from: htmlForAnalysis)
            return isLikelyTransactionalOrMarketingContent(
                lowercasedHTML: lowercased,
                textContent: textContent,
                linkCount: linkCount,
                hasNewsletterIndicators: hasNewsletterIndicators
            )
        }

        // Extract approximate text content length (rough estimate without full parsing)
        let textContent = approximateTextContent(from: htmlForAnalysis)

        // Check for CSS background images (often used in marketing emails)
        let hasBackgroundImages = lowercased.contains("background-image") ||
                                   lowercased.contains("background:url") ||
                                   lowercased.contains("background: url")

        // Check for button/CTA elements (common in marketing emails)
        let hasButtonElements = lowercased.contains("class=\"button") ||
                                 lowercased.contains("class='button") ||
                                 lowercased.contains("role=\"button") ||
                                 lowercased.contains("class=\"btn") ||
                                 lowercased.contains("class=\"cta")

        let hasTransactionalSignals = isLikelyTransactionalOrMarketingContent(
            lowercasedHTML: lowercased,
            textContent: textContent,
            linkCount: linkCount,
            hasNewsletterIndicators: hasNewsletterIndicators
        )

        // Professional signatures (real estate agents, etc.) can have:
        // - 1 company logo + 1 headshot + 6-8 social icons = up to 10 images
        // - 3-4 layout tables for contact info formatting
        // - Multiple CID references for inline images
        // Increased thresholds to accommodate elaborate professional signatures
        let isLikelySignatureOnly = imgCount <= 10 && tableCount <= 5 && cidCount <= 10 &&
                                    !hasBackgroundImages && !hasButtonElements

        // If it looks like just signature elements, don't flag as rich
        if isLikelySignatureOnly {
            // Newsletters can be mostly text with a footer - treat as rich to preserve formatting
            if hasNewsletterIndicators && textContent.count > 200 {
                return true
            }

            // But check link density - newsletters often have many links
            // If >15 links, it's likely a newsletter regardless of other indicators
            if linkCount > 15 {
                return true
            }

            // Transactional emails (e.g., security alerts) often use a small number of tables
            // with substantial text content. Treat these as rich to preserve formatting.
            if tableCount >= 2 && textContent.count > 200 {
                return true
            }

            // Some bank/financial notifications use a single dense table template.
            // Classify these as rich when transactional cues are explicit.
            if tableCount >= 1 && hasTransactionalSignals {
                return true
            }

            return false
        }

        // For content above signature thresholds, check if it's genuinely rich content
        // or just an elaborate signature with little actual message text
        let totalElements = imgCount + tableCount + cidCount

        // Newsletters have substantial text content relative to elements
        // Signatures have many elements but relatively little text
        // Use ratio: if less than 50 chars per element, likely signature-heavy
        let charsPerElement = totalElements > 0 ? textContent.count / totalElements : textContent.count

        // If there's very little text relative to the number of elements, it's likely just signature
        if charsPerElement < 50 && textContent.count < 500 {
            // Table-heavy transactional templates (bill approvals, account notices) often have
            // dense structure and concise copy; keep them in HTML preview when explicit CTA
            // or transactional/newsletter signals are present.
            if tableCount >= 6 && (hasButtonElements || hasNewsletterIndicators || hasTransactionalSignals) {
                return true
            }

            // Exception: high link density with reasonable text suggests newsletter
            if linkCount > 15 && textContent.count > 300 {
                return true
            }
            return false
        }

        // If it has newsletter indicators and many elements, it's rich content
        if hasNewsletterIndicators && totalElements > 5 {
            return true
        }

        // Background images or button elements with substantial content = rich
        if (hasBackgroundImages || hasButtonElements) && textContent.count > 300 {
            return true
        }

        // Otherwise, use a lightweight weighted score to decide
        var score = 0

        // Structural complexity
        score += min(imgCount * 2, 20)
        score += min(tableCount * 3, 30)
        score += min(linkCount, 20)
        if cidCount > 0 { score += 5 }

        // Marketing/newsletter signals
        if hasBackgroundImages { score += 15 }
        if hasButtonElements { score += 10 }
        if hasNewsletterIndicators { score += 25 }

        // Text presence (avoid image-only promos)
        if textContent.count > 200 { score += 10 }
        if textContent.count > 500 { score += 10 }

        // Penalize signature-heavy layouts
        if charsPerElement < 40 && textContent.count < 400 { score -= 10 }

        return score >= 40
    }

    /// Heuristic for transactional/marketing content that should stay in HTML preview mode.
    /// Personal long-form messages should remain bubbles unless we see explicit cues.
    nonisolated private static func isLikelyTransactionalOrMarketingContent(
        lowercasedHTML: String,
        textContent: String,
        linkCount: Int,
        hasNewsletterIndicators: Bool
    ) -> Bool {
        guard textContent.count > 200 else { return false }

        if hasNewsletterIndicators {
            return true
        }

        let lowercasedText = textContent.lowercased()
        let transactionalPatterns = [
            "security alert",
            "new sign-in",
            "new signin",
            "if this wasn't you",
            "if this was not you",
            "review activity",
            "verify your",
            "confirm your",
            "password reset",
            "reset your password",
            "one-time passcode",
            "one time passcode",
            "statement is ready",
            "account activity",
            "account number ending",
            "account ending in",
            "service message",
            "invoice",
            "receipt",
            "order confirmation",
            "tracking number",
            "payment receipt",
            "deposit declined",
            "daily deposit limit",
            "mobile check deposit"
        ]

        var transactionalHitCount = 0
        for pattern in transactionalPatterns where lowercasedText.contains(pattern) || lowercasedHTML.contains(pattern) {
            transactionalHitCount += 1
        }

        let hasNoReplyLanguage = lowercasedText.contains("do not reply") ||
                                 lowercasedText.contains("don't reply") ||
                                 lowercasedText.contains("do not respond") ||
                                 lowercasedText.contains("don't respond") ||
                                 lowercasedText.contains("noreply") ||
                                 lowercasedText.contains("no-reply")
        if hasNoReplyLanguage {
            transactionalHitCount += 1
        }

        // High link density in simple wrappers is usually promotional/newsletter content.
        if linkCount >= 6 {
            return true
        }

        if linkCount >= 2 && transactionalHitCount >= 1 {
            return true
        }

        if transactionalHitCount >= 2 {
            return true
        }

        // Very long account-notification style emails with at least one strong signal.
        return transactionalHitCount >= 1 && textContent.count > 700
    }

    /// Strips Apple Mail "rich link" preview blocks from HTML so we don't treat them as newsletter/marketing content.
    ///
    /// Apple Mail inserts a `<div class="apple-rich-link" ...>` container with nested tables/links and `role="button"`.
    /// This is common in personal messages that include a URL and should not trigger HTML preview cards.
    nonisolated private static func stripAppleRichLinkPreviews(from html: String) -> String {
        var result = html
        var searchStart = result.startIndex

        // Remove every `<div ... class="apple-rich-link" ...>...</div>` block
        // (including nested divs). Each scan resumes from the removal point —
        // restarting from index 0 made k blocks cost k full passes over the
        // document (quadratic on crafted input). Nothing before the removal
        // point can still contain a marker: the earliest marker's enclosing
        // div starts at or before it and was just removed.
        while searchStart < result.endIndex,
              let markerRange = result.range(
                of: "apple-rich-link",
                options: .caseInsensitive,
                range: searchStart..<result.endIndex
              ) {
            // Find the opening `<div` tag that contains the marker (class attribute is inside the tag).
            guard let divStart = result[..<markerRange.lowerBound]
                .range(of: "<div", options: [.caseInsensitive, .backwards])?
                .lowerBound else {
                break
            }
            guard let endIndex = findMatchingClosingDiv(in: result, from: divStart) else {
                break
            }
            // String indices are invalidated by mutation; carry the resume
            // point across the removal as an offset.
            let resumeOffset = result.distance(from: result.startIndex, to: divStart)
            result.removeSubrange(divStart..<endIndex)
            searchStart = result.index(result.startIndex, offsetBy: resumeOffset)
        }

        return result
    }

    /// Finds the end index (exclusive) of the closing `</div>` that matches the opening `<div` at `start`.
    /// Uses a lightweight depth counter so nested `<div>` elements inside the block are handled correctly.
    nonisolated private static func findMatchingClosingDiv(in html: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var searchIndex = start

        while searchIndex < html.endIndex {
            let nextOpen = html.range(of: "<div", options: .caseInsensitive, range: searchIndex..<html.endIndex)
            let nextClose = html.range(of: "</div", options: .caseInsensitive, range: searchIndex..<html.endIndex)

            switch (nextOpen, nextClose) {
            case let (open?, close?):
                if open.lowerBound < close.lowerBound {
                    depth += 1
                    searchIndex = open.upperBound
                } else {
                    depth -= 1
                    guard let closeTagEnd = html[close.lowerBound...].firstIndex(of: ">") else { return nil }
                    let afterClose = html.index(after: closeTagEnd)
                    searchIndex = afterClose
                    if depth == 0 {
                        return afterClose
                    }
                }
            case let (open?, nil):
                depth += 1
                searchIndex = open.upperBound
            case let (nil, close?):
                depth -= 1
                guard let closeTagEnd = html[close.lowerBound...].firstIndex(of: ">") else { return nil }
                let afterClose = html.index(after: closeTagEnd)
                searchIndex = afterClose
                if depth == 0 {
                    return afterClose
                }
            case (nil, nil):
                return nil
            }
        }

        return nil
    }

    nonisolated fileprivate static func extractPlainTextFromHTML(
        from html: String,
        decodeHTMLEntities: Bool = false,
        formatSignOffLineBreaks: Bool = true,
        applyPlainTextQuoteRemoval: Bool = false
    ) -> String? {
        // HTML compatibility fallback for records missing chatPreviewText. The
        // extraction itself is DOM-backed; the plain-text quote cleanup below is
        // only used when HTML quote cleanup leaves no meaningful content.
        let extracted = TextProcessing.extractPlainText(from: html)
        guard !extracted.isEmpty else { return nil }

        let decoded = decodeHTMLEntities ? HTMLEntityDecoder.decode(extracted) : extracted
        let textBeforeUnwrap = applyPlainTextQuoteRemoval
            ? decoded
            : removeConsecutivePlainTextQuoteLines(from: decoded)
        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: textBeforeUnwrap)
        let quoteRemoved: String
        if applyPlainTextQuoteRemoval {
            quoteRemoved = PlainTextQuoteRemover.extractQuotes(from: unwrapped).mainContent
        } else {
            let headerRemoved = removePlainTextHeaderQuoteBlocks(from: unwrapped)
            quoteRemoved = removeResidualHTMLTextQuoteMarkers(from: headerRemoved)
        }
        let formatted = formatSignOffLineBreaks
            ? TextProcessing.formatSignOffLineBreaks(in: quoteRemoved)
            : quoteRemoved
        let trimmed = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func removeConsecutivePlainTextQuoteLines(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return text }

        var consecutiveQuoteLineCount = 0
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                consecutiveQuoteLineCount += 1
                if consecutiveQuoteLineCount >= 2 {
                    var firstQuoteLineIndex = index - consecutiveQuoteLineCount + 1
                    if firstQuoteLineIndex > 0 {
                        let precedingLine = lines[firstQuoteLineIndex - 1].trimmingCharacters(in: .whitespaces)
                        if isHTMLTextQuoteAttributionLine(precedingLine) {
                            firstQuoteLineIndex -= 1
                        }
                    }
                    return lines[..<firstQuoteLineIndex].joined(separator: "\n")
                }
            } else {
                consecutiveQuoteLineCount = 0
            }
        }

        return text
    }

    nonisolated private static func isHTMLTextQuoteAttributionLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let attributionSuffixes = [
            "wrote:", "schrieb:", "a écrit :", "a écrit:", "escribió:",
            "ha scritto:", "escreveu:", "schreef:"
        ]
        return attributionSuffixes.contains(where: { lowercased.hasSuffix($0) })
    }

    private static let residualHTMLTextQuoteMarkerPatterns: [NSRegularExpression] = {
        let rawPatterns = [
            #"(?im)(?:^|\n)\s*begin forwarded message:\s*"#,
            #"(?im)(?:^|\n)\s*-{2,}\s*forwarded message\b[^\n]*"#,
            #"(?im)\s-{2,}\s*forwarded message\b[^\n]*"#,
            #"(?im)(?:^|\n)\s*-{2,}\s*original message\s*-{2,}[^\n]*"#,
            #"(?im)(?:^|\n)\s*Am .{1,200}? schrieb .{1,120}\s*:\s*"#,
            #"(?im)(?:^|\n)\s*Le .{1,200}? a écrit\s*:\s*"#,
            #"(?im)(?:^|\n)\s*El .{1,200}? escribió\s*:\s*"#,
            #"(?im)(?:^|\n)\s*Il .{1,200}? ha scritto\s*:\s*"#,
            #"(?im)(?:^|\n)\s*Em .{1,200}? escreveu\s*:\s*"#,
            #"(?im)(?:^|\n)\s*Op .{1,200}? schreef .{1,120}\s*:\s*"#
        ]
        return rawPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    nonisolated private static func removeResidualHTMLTextQuoteMarkers(from text: String) -> String {
        let range = NSRange(location: 0, length: text.utf16.count)
        let earliestMatch = residualHTMLTextQuoteMarkerPatterns
            .compactMap { pattern in
                pattern.firstMatch(in: text, options: [], range: range)
            }
            .min { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    return lhs.range.length < rhs.range.length
                }
                return lhs.range.location < rhs.range.location
            }

        guard let earliestMatch,
              let matchRange = Range(earliestMatch.range, in: text) else {
            return text
        }

        return String(text[..<matchRange.lowerBound])
    }

    private static let htmlTextFromHeaderPrefixesLowercased: [String] = [
        "from:", "von:", "de:", "de :", "da:", "van:"
    ]

    private static let htmlTextToHeaderPrefixesLowercased: [String] = [
        "to:", "an:", "à:", "à :", "para:", "aan:"
    ]

    private static let htmlTextSentOrDateHeaderPrefixesLowercased: [String] = [
        "sent:", "date:", "gesendet:", "datum:", "envoyé:", "envoyé :", "enviado:", "inviato:", "verzonden:"
    ]

    private static let htmlTextEmailPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive])
    }()

    nonisolated private static func removePlainTextHeaderQuoteBlocks(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.count > 1 else { return text }

        var lineStartOffsets: [Int] = []
        lineStartOffsets.reserveCapacity(lines.count)
        var runningOffset = 0
        for (index, line) in lines.enumerated() {
            lineStartOffsets.append(runningOffset)
            runningOffset += line.count
            if index < lines.count - 1 {
                runningOffset += 1
            }
        }

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let lowercased = trimmed.lowercased()
            guard htmlTextFromHeaderPrefixesLowercased.contains(where: { lowercased.hasPrefix($0) }) else {
                continue
            }

            guard index > 0,
                  lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            var sawTo = false
            var sawSentOrDate = false
            var sawEmailAddress = containsHTMLTextEmailAddress(trimmed)
            let upperBound = min(lines.count, index + 24)

            if index + 1 < upperBound {
                for candidateIndex in (index + 1)..<upperBound {
                    let candidate = lines[candidateIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty else { continue }

                    let candidateLower = candidate.lowercased()
                    if htmlTextToHeaderPrefixesLowercased.contains(where: { candidateLower.hasPrefix($0) }) {
                        sawTo = true
                    }
                    if htmlTextSentOrDateHeaderPrefixesLowercased.contains(where: { candidateLower.hasPrefix($0) }) {
                        sawSentOrDate = true
                    }
                    if containsHTMLTextEmailAddress(candidate) {
                        sawEmailAddress = true
                    }

                    if sawTo && sawSentOrDate && sawEmailAddress,
                       let removalIndex = text.index(text.startIndex, offsetBy: lineStartOffsets[index], limitedBy: text.endIndex) {
                        return String(text[..<removalIndex])
                    }
                }
            }
        }

        return text
    }

    nonisolated private static func containsHTMLTextEmailAddress(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: text.utf16.count)
        return htmlTextEmailPattern?.firstMatch(in: text, options: [], range: range) != nil
    }

    nonisolated fileprivate static func cleanedHTMLForProcessing(_ html: String) -> HTMLProcessingCleanupResult {
        let quotedAndSignature = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures) ?? html
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(quotedAndSignature) {
            return HTMLProcessingCleanupResult(html: quotedAndSignature, applyPlainTextQuoteRemoval: false)
        }

        // Signature cleanup false-positive; try quote-only cleanup.
        let quotedOnly = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedOnly) ?? html
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(quotedOnly) {
            return HTMLProcessingCleanupResult(html: quotedOnly, applyPlainTextQuoteRemoval: false)
        }

        return HTMLProcessingCleanupResult(html: html, applyPlainTextQuoteRemoval: true)
    }

    nonisolated private static func approximateTextContent(from html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Counts HTML elements using efficient substring search
    /// Returns (imgCount, tableCount, cidCount, linkCount)
    nonisolated private static func countHTMLElements(_ html: String) -> (Int, Int, Int, Int) {
        let imgCount = countOccurrences(of: "<img", in: html)
        let tableCount = countOccurrences(of: "<table", in: html)
        let cidCount = countOccurrences(of: "cid:", in: html)
        // Count <a> tags - need to check for both "<a " and "<a>" patterns
        let linkCountSpace = countOccurrences(of: "<a ", in: html)
        let linkCountDirect = countOccurrences(of: "<a>", in: html)

        return (imgCount, tableCount, cidCount, linkCountSpace + linkCountDirect)
    }

    /// Counts case-insensitive occurrences of a substring
    nonisolated private static func countOccurrences(of substring: String, in string: String) -> Int {
        var count = 0
        var searchRange = string.startIndex..<string.endIndex

        while let foundRange = string.range(of: substring, options: .caseInsensitive, range: searchRange) {
            count += 1
            searchRange = foundRange.upperBound..<string.endIndex
        }

        return count
    }

    /// Detects simple div-wrapped text (Gmail mobile format) that should display as plain text
    /// Example: <div dir="auto">Line 1</div><div dir="auto"><br></div><div dir="auto">Line 2</div>
    /// - Parameters:
    ///   - html: The original HTML string (used for regex replacement)
    ///   - lowercased: Pre-lowercased version of the HTML for efficient contains() checks
    nonisolated private static func isSimpleDivWrappedText(_ html: String, lowercased: String) -> Bool {

        // Must have divs (the wrapper pattern we're detecting)
        guard lowercased.contains("<div") else { return false }

        // Rich content indicators that disqualify simple text
        let richIndicators = [
            "<table", "<img", "<video", "<iframe", "<object", "<embed",
            "<article", "<section", "<header", "<footer", "<nav",
            "<style", "background-image", "background:url", "background: url",
            "class=\"button", "class=\"btn", "class=\"cta", "role=\"button"
        ]

        for indicator in richIndicators {
            if lowercased.contains(indicator) {
                return false
            }
        }

        // Check if content is predominantly simple div/span wrappers
        // Strip simple formatting tags and count what HTML tags remain
        let afterSimpleStrip = html
            .replacingOccurrences(of: "</?(?:div|span|br|p|a|b|i|strong|em|font|blockquote)[^>]*>",
                                  with: "", options: .regularExpression)

        // Count remaining HTML tags (complex tags that weren't stripped)
        let remainingTagCount = afterSimpleStrip.components(separatedBy: "<").count - 1
        return remainingTagCount == 0
    }

    func clear() async {
        await cache.clear()
        cacheKeysByMessageID.removeAll()
        cacheKeyTrackingVersion &+= 1
    }

    /// Invalidates a specific cache entry by message ID.
    /// Use this when a Message entity is deleted.
    func invalidate(messageId: String) async {
        let trackedKeys = cacheKeysByMessageID.removeValue(forKey: messageId) ?? []
        cacheKeyTrackingVersion &+= 1
        let legacyKey = Self.cacheKey(for: messageId)
        for key in trackedKeys.union([legacyKey]) {
            await cache.remove(key)
        }
        await RenderedMessageCache.shared.invalidate(messageId: messageId, reason: .explicit)
    }

    /// Returns cache statistics for monitoring
    func getStatistics() async -> LRUCacheStatistics {
        await cache.getStatistics()
    }

    private func trackCacheKey(_ key: String, for messageId: String) {
        cacheKeysByMessageID[messageId, default: []].insert(key)
        cacheKeyTrackingVersion &+= 1
    }

    private func beginTrackedCacheWrite(_ key: String, for messageId: String) {
        inFlightTrackedCacheWriteCount += 1
        trackCacheKey(key, for: messageId)
    }

    private func finishTrackedCacheWrite() {
        guard inFlightTrackedCacheWriteCount > 0 else { return }
        inFlightTrackedCacheWriteCount -= 1
    }

    private func pruneTrackedCacheKeys() async {
        guard inFlightTrackedCacheWriteCount == 0 else {
            return
        }

        let trackingVersion = cacheKeyTrackingVersion
        let liveKeys = Set(await cache.allKeys())
        guard cacheKeyTrackingVersion == trackingVersion,
              inFlightTrackedCacheWriteCount == 0 else {
            return
        }

        cacheKeysByMessageID = cacheKeysByMessageID.reduce(into: [:]) { result, entry in
            let retainedKeys = entry.value.intersection(liveKeys)
            if !retainedKeys.isEmpty {
                result[entry.key] = retainedKeys
            }
        }
        cacheKeyTrackingVersion &+= 1
    }

#if DEBUG
    func trackedCacheKeyCountForTesting() -> Int {
        cacheKeysByMessageID.values.reduce(0) { $0 + $1.count }
    }

    func beginTrackedCacheWriteForTesting(messageId: String, sourceSignature: String, previewMode: String) {
        let key = Self.cacheKey(
            for: messageId,
            sourceSignature: sourceSignature,
            previewMode: previewMode
        )
        beginTrackedCacheWrite(key, for: messageId)
    }

    func finishTrackedCacheWriteForTesting() {
        finishTrackedCacheWrite()
    }
#endif
}
