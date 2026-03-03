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

    private static func processHTML(
        _ html: String,
        decodeHTMLEntities: Bool,
        formatSignOffLineBreaks: Bool,
        classifyRichContent: Bool
    ) -> ChatBubbleTextProcessingResult {
        // Strip quoted/signature content from HTML first. If that pass removes too much
        // (e.g., transactional templates), fall back to quote-only cleanup or original HTML.
        let cleanedHTML = ProcessedTextCache.cleanedHTMLForProcessing(html)

        var plainTextAndQuotes = ProcessedTextCache.extractPlainTextAndQuotes(
            from: cleanedHTML,
            decodeHTMLEntities: decodeHTMLEntities,
            formatSignOffLineBreaks: formatSignOffLineBreaks
        )

        if plainTextAndQuotes.plainText == nil {
            plainTextAndQuotes = ProcessedTextCache.extractPlainTextAndQuotes(
                from: html,
                decodeHTMLEntities: decodeHTMLEntities,
                formatSignOffLineBreaks: formatSignOffLineBreaks
            )
        }

        let hasRichContent = classifyRichContent ? ProcessedTextCache.hasGenuineRichContent(cleanedHTML) : false
        return ChatBubbleTextProcessingResult(
            mainText: plainTextAndQuotes.plainText,
            quotedParts: plainTextAndQuotes.quotedParts,
            hasRichContent: hasRichContent
        )
    }

    private static func processPlainText(
        _ text: String,
        sanitizeRawEmailSource: Bool,
        decodeHTMLEntities: Bool,
        formatSignOffLineBreaks: Bool
    ) -> ChatBubbleTextProcessingResult {
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

    private static func containsHTMLTags(_ text: String) -> Bool {
        guard let regex = htmlTagPattern else {
            return text.contains("<") && text.contains(">")
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}

/// Thread-safe cache for processed message text content
/// Eliminates redundant HTML parsing and regex operations during scroll
/// Uses LRUCacheActor for automatic eviction management
actor ProcessedTextCache: MemoryWarningHandler {
    static let shared = ProcessedTextCache()
    // Bump to invalidate cached entries when processing logic changes.
    private static let processingVersion = "2026-03-02-chat-bubble-unified-v3"

    /// Cached text content with rich content indicator and extracted quotes
    struct CachedText: Sendable {
        let plainText: String?
        let hasRichContent: Bool
        let quotedParts: [QuotedPart]

        init(plainText: String?, hasRichContent: Bool, quotedParts: [QuotedPart] = []) {
            self.plainText = plainText
            self.hasRichContent = hasRichContent
            self.quotedParts = quotedParts
        }
    }

    private let cache: LRUCacheActor<String, CachedText>

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

    func get(messageId: String) async -> (plainText: String?, hasRichContent: Bool, quotedParts: [QuotedPart])? {
        guard let entry = await cache.get(Self.cacheKey(for: messageId)) else { return nil }
        return (entry.plainText, entry.hasRichContent, entry.quotedParts)
    }

    func set(messageId: String, plainText: String?, hasRichContent: Bool, quotedParts: [QuotedPart] = []) async {
        let size = Self.estimateSize(plainText, hasRichContent, quotedParts)
        await cache.set(
            Self.cacheKey(for: messageId),
            value: CachedText(plainText: plainText, hasRichContent: hasRichContent, quotedParts: quotedParts),
            sizeBytes: size
        )
    }

    func prefetch(messageIds: [String]) async {
        // Filter out already cached messages
        var uncachedIds: [String] = []
        for messageId in messageIds {
            if await !cache.contains(Self.cacheKey(for: messageId)) {
                uncachedIds.append(messageId)
            }
        }
        guard !uncachedIds.isEmpty else { return }

        // Limit batch size to prevent processing too many at once
        let idsToProcess = Array(uncachedIds.prefix(maxPrefetchBatchSize))

        // Cancel any existing prefetch task to prevent accumulation during rapid scroll
        activePrefetchTask?.cancel()

        // Generate unique ID for this task to prevent race conditions on cleanup
        let taskId = UUID()
        activePrefetchTaskId = taskId

        // Track the new prefetch task
        activePrefetchTask = Task.detached(priority: .utility) { [weak self, idsToProcess, taskId] in
            let handler = HTMLContentHandler.shared

            for messageId in idsToProcess {
                // Check for cancellation between messages
                guard !Task.isCancelled else { break }

                let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)

                // Check again before cache write to prevent cancelled tasks from writing stale data
                guard !Task.isCancelled else { break }

                await self?.set(messageId: messageId, plainText: result.plainText, hasRichContent: result.hasRichContent, quotedParts: result.quotedParts)
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
            let result = ChatBubbleTextProcessor.process(
                content: html,
                options: ChatBubbleTextProcessorOptions(
                    inputKind: .html,
                    sanitizeRawEmailSource: false,
                    decodeHTMLEntities: true,
                    formatSignOffLineBreaks: true,
                    classifyRichContent: true
                )
            )
            return (result.mainText, result.hasRichContent, result.quotedParts)
        }

        return (nil, false, [])
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

        // Remove every `<div ... class="apple-rich-link" ...>...</div>` block (including nested divs).
        while let markerRange = result.range(of: "apple-rich-link", options: .caseInsensitive) {
            // Find the opening `<div` tag that contains the marker (class attribute is inside the tag).
            guard let divStart = result[..<markerRange.lowerBound]
                .range(of: "<div", options: [.caseInsensitive, .backwards])?
                .lowerBound else {
                break
            }
            guard let endIndex = findMatchingClosingDiv(in: result, from: divStart) else {
                break
            }
            result.removeSubrange(divStart..<endIndex)
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

    nonisolated fileprivate static func extractPlainTextAndQuotes(
        from html: String,
        decodeHTMLEntities: Bool = false,
        formatSignOffLineBreaks: Bool = true
    ) -> (plainText: String?, quotedParts: [QuotedPart]) {
        let extracted = TextProcessing.extractPlainText(from: html)
        guard !extracted.isEmpty else { return (nil, []) }

        let decoded = decodeHTMLEntities ? HTMLEntityDecoder.decode(extracted) : extracted
        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: decoded)
        let extractionResult = PlainTextQuoteRemover.extractQuotes(from: unwrapped)
        let formatted = formatSignOffLineBreaks
            ? TextProcessing.formatSignOffLineBreaks(in: extractionResult.mainContent)
            : extractionResult.mainContent
        return (formatted.isEmpty ? nil : formatted, extractionResult.quotedParts)
    }

    nonisolated fileprivate static func cleanedHTMLForProcessing(_ html: String) -> String {
        let quotedAndSignature = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures) ?? html
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(quotedAndSignature) {
            return quotedAndSignature
        }

        // Signature cleanup false-positive; try quote-only cleanup.
        let quotedOnly = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedOnly) ?? html
        if HTMLMeaningfulContentChecker.hasMeaningfulContent(quotedOnly) {
            return quotedOnly
        }

        return html
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
    }

    /// Invalidates a specific cache entry by message ID.
    /// Use this when a Message entity is deleted.
    func invalidate(messageId: String) async {
        await cache.remove(Self.cacheKey(for: messageId))
    }

    /// Returns cache statistics for monitoring
    func getStatistics() async -> LRUCacheStatistics {
        await cache.getStatistics()
    }
}
