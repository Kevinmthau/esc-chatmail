import Foundation

/// Thread-safe cache for processed message text content
/// Eliminates redundant HTML parsing and regex operations during scroll
/// Uses LRUCacheActor for automatic eviction management
actor ProcessedTextCache: MemoryWarningHandler {
    static let shared = ProcessedTextCache()
    // Bump to invalidate cached entries when processing logic changes.
    private static let processingVersion = "2026-02-11-quote-v5-signature-unicode-separators"

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
        var plainTextAndQuotes: (plainText: String?, quotedParts: [QuotedPart])?
        var hasRichContent = false

        let html = loadHTML(messageId: messageId, bodyStorageURI: bodyStorageURI, handler: handler)
        if let html {
            // Strip quoted content from HTML first
            let cleanedHTML = HTMLQuoteRemover.removeQuotes(from: html) ?? html

            plainTextAndQuotes = extractPlainTextAndQuotes(from: cleanedHTML)

            // If quote removal stripped everything, try without HTML quote removal
            if plainTextAndQuotes?.plainText == nil {
                plainTextAndQuotes = extractPlainTextAndQuotes(from: html)
            }

            // Check for rich content in cleaned HTML only (not quoted sections)
            // Uses heuristic to distinguish newsletters from personal emails with signature cruft
            hasRichContent = hasGenuineRichContent(cleanedHTML)
        }

        return (
            plainTextAndQuotes?.plainText,
            hasRichContent,
            plainTextAndQuotes?.quotedParts ?? []
        )
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
              let url = resolveStorageURI(urlString),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return handler.loadHTML(from: url)
    }

    nonisolated private static func resolveStorageURI(_ urlString: String) -> URL? {
        if urlString.starts(with: "/") {
            return URL(fileURLWithPath: urlString)
        } else if urlString.starts(with: "file://") {
            return URL(string: urlString)
        } else {
            return URL(string: urlString)
        }
    }

    /// Determines if HTML contains genuine rich content (newsletters, receipts) vs personal email signature cruft
    /// Personal emails can have elaborate signatures (logo + headshot + 6-8 social icons + layout tables)
    /// Newsletters and marketing emails have many elements AND substantial text content
    nonisolated private static func hasGenuineRichContent(_ html: String) -> Bool {
        let lowercased = html.lowercased()

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
        let (imgCount, tableCount, cidCount, linkCount) = countHTMLElements(html)

        // Early exit for simple div-wrapped text (common Gmail mobile format)
        // Must check AFTER element counts since we want to catch cases with 0 images/tables
        // BUT: transactional emails (Google security alerts, etc.) have substantial text
        // in simple divs and should still show as HTML to preserve formatting
        if imgCount == 0 && tableCount == 0 && cidCount == 0 && isSimpleDivWrappedText(html, lowercased: lowercased) {
            // Check if there's substantial text content before downgrading to plain text
            let textContent = approximateTextContent(from: html)

            // If substantial text content, keep as HTML to preserve formatting
            if textContent.count > 200 {
                return true
            }
            return false
        }

        // Extract approximate text content length (rough estimate without full parsing)
        let textContent = approximateTextContent(from: html)

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

        // Newsletter indicators that imply rich content even when there are few images/tables
        let hasNewsletterIndicators = lowercased.contains("unsubscribe") ||
                                       lowercased.contains("view in browser") ||
                                       lowercased.contains("email preferences") ||
                                       lowercased.contains("privacy policy") ||
                                       lowercased.contains("manage preferences") ||
                                       lowercased.contains("update your preferences")

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

    nonisolated private static func extractPlainTextAndQuotes(
        from html: String
    ) -> (plainText: String?, quotedParts: [QuotedPart]) {
        let extracted = TextProcessing.extractPlainText(from: html)
        guard !extracted.isEmpty else { return (nil, []) }

        let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: extracted)
        let extractionResult = PlainTextQuoteRemover.extractQuotes(from: unwrapped)
        let formatted = TextProcessing.formatSignOffLineBreaks(in: extractionResult.mainContent)
        return (formatted.isEmpty ? nil : formatted, extractionResult.quotedParts)
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

// MARK: - Text Processing Helpers (nonisolated for background thread usage)
enum TextProcessing {
    /// Pre-compiled regex for list item detection
    /// Matches: 1. 10. 100. a) A. - * • · (a) (1)
    private static let listItemPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "^(\\d{1,3}[.)]|[a-zA-Z][.)]|[-*•·]|\\([a-zA-Z0-9]{1,3}\\))\\s",
            options: []
        )
    }()

    /// Checks if a line starts with a list item marker
    static func isListItem(_ line: String) -> Bool {
        guard let regex = listItemPattern else {
            // Fallback to simple check
            return line.hasPrefix("-") || line.hasPrefix("*") || line.hasPrefix("•") || line.hasPrefix("·")
        }
        let range = NSRange(location: 0, length: min(line.utf16.count, 10)) // Only check first 10 chars
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }
    static func extractPlainText(from html: String) -> String {
        var text = html

        // Remove script and style tags and their content
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression, range: nil)

        // Convert consecutive <br> tags to paragraph breaks, single <br> to space (soft wrap)
        // First: <br><br> or <br>\s*<br> → paragraph break
        text = text.replacingOccurrences(of: "<br[^>]*>\\s*<br[^>]*>", with: "\n\n", options: .regularExpression, range: nil)
        // Then: remaining single <br> → newline (let unwrapEmailLineBreaks decide whether to join)
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression, range: nil)

        // Paragraphs and headings get double newlines (actual content breaks)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "</h[1-6]>", with: "\n\n", options: .regularExpression, range: nil)

        // Div closures create single newlines - let unwrapEmailLineBreaks decide whether to join
        // Gmail mobile wraps each line in <div>, so using \n allows smart join logic to work
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive, range: nil)

        // List items should each appear on their own line
        text = text.replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive, range: nil)

        // Remove all HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
        // Remove truncated opening tags (e.g., snippet cut in middle of `<div style="...`).
        text = text.replacingOccurrences(of: "<[a-zA-Z][^>\\n]*(?=\\n|$)", with: "", options: .regularExpression, range: nil)

        // Decode HTML entities (non-breaking space variants)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&#160;", with: " ")
        text = text.replacingOccurrences(of: "&#xA0;", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&#34;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")

        // Zero-width characters (strip entirely - they're invisible formatting)
        text = text.replacingOccurrences(of: "&zwnj;", with: "")
        text = text.replacingOccurrences(of: "&zwj;", with: "")
        text = text.replacingOccurrences(of: "&#8204;", with: "")
        text = text.replacingOccurrences(of: "&#8205;", with: "")
        text = text.replacingOccurrences(of: "&#x200C;", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&#x200D;", with: "", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "\u{200C}", with: "")
        text = text.replacingOccurrences(of: "\u{200D}", with: "")
        text = text.replacingOccurrences(of: "\u{200B}", with: "") // zero-width space

        // Smart quotes and other typographic entities
        text = text.replacingOccurrences(of: "&ldquo;", with: "\"")
        text = text.replacingOccurrences(of: "&rdquo;", with: "\"")
        text = text.replacingOccurrences(of: "&lsquo;", with: "'")
        text = text.replacingOccurrences(of: "&rsquo;", with: "'")
        text = text.replacingOccurrences(of: "&#8220;", with: "\"")
        text = text.replacingOccurrences(of: "&#8221;", with: "\"")
        text = text.replacingOccurrences(of: "&#8216;", with: "'")
        text = text.replacingOccurrences(of: "&#8217;", with: "'")
        text = text.replacingOccurrences(of: "&ndash;", with: "–")
        text = text.replacingOccurrences(of: "&mdash;", with: "—")
        text = text.replacingOccurrences(of: "&#8211;", with: "–")
        text = text.replacingOccurrences(of: "&#8212;", with: "—")
        text = text.replacingOccurrences(of: "&hellip;", with: "…")
        text = text.replacingOccurrences(of: "&#8230;", with: "…")

        // Clean up whitespace
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression, range: nil)
        // Collapse whitespace-only lines to single newline
        text = text.replacingOccurrences(of: "\\n[ \\t]*\\n", with: "\n\n", options: .regularExpression, range: nil)
        // Collapse any sequence of newlines (with optional whitespace) to max 2 newlines
        text = text.replacingOccurrences(of: "(\\s*\\n\\s*){2,}", with: "\n\n", options: .regularExpression, range: nil)

        // Trim whitespace from each line to clean up artifacts like " \n" from decoded &nbsp;
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    static func stripQuotedText(from text: String) -> String {
        // Delegate to PlainTextQuoteRemover for unified quote and signature removal
        PlainTextQuoteRemover.removeQuotes(from: text) ?? text
    }

    static func stripSignatures(from text: String) -> String {
        PlainTextSignatureRemover.removeSignature(from: text)
    }

    /// Common sign-off words that should have a line break before them
    private static let signOffWords = ["regards", "thanks", "thank you", "best", "cheers", "sincerely", "yours truly", "best wishes", "kind regards", "warm regards", "take care", "all the best"]

    /// Adds line breaks before sign-offs when they appear inline at the end of text
    /// Handles cases like "...for your help. Regards, Kevin" → "...for your help.\n\nRegards,\n\nKevin"
    static func formatSignOffLineBreaks(in text: String) -> String {
        var result = text

        // Pattern: sentence ending (. ! ?) followed by space and a sign-off word
        for signOff in signOffWords {
            // Case-insensitive search for ". SignOff" pattern
            let patterns = [
                "([.!?])\\s+(\(signOff))([!.])?,?\\s*$",  // "help. Regards" or "help. Thanks!" at end - group 3 captures trailing punct
                "([.!?])\\s+(\(signOff)),\\s+([A-Z][a-z]+)\\s*$",  // "help. Regards, Kevin" at end
                "([.!?])\\s+(\(signOff)),\\s+([A-Z][a-z]+)\\s+([A-Z][a-z]+)\\s*$",  // "help. Regards, Kevin Thau" at end
            ]

            for (patternIndex, pattern) in patterns.enumerated() {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let range = NSRange(location: 0, length: result.utf16.count)
                    if let match = regex.firstMatch(in: result, options: [], range: range) {
                        // Found a sign-off pattern - add line breaks
                        let punctuation = (result as NSString).substring(with: match.range(at: 1))
                        let signOffText = (result as NSString).substring(with: match.range(at: 2))

                        // First pattern captures trailing punctuation in group 3; others have name in group 3
                        let trailingPunct: String
                        if patternIndex == 0 && match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound {
                            trailingPunct = (result as NSString).substring(with: match.range(at: 3))
                        } else {
                            trailingPunct = ","
                        }

                        var replacement = "\(punctuation)\n\n\(signOffText)\(trailingPunct)"
                        // For patterns 2 and 3 (with names), group 3 is first name, group 4 is last name
                        if patternIndex > 0 && match.numberOfRanges > 3 {
                            let name = (result as NSString).substring(with: match.range(at: 3))
                            replacement += "\n\n\(name)"
                            if match.numberOfRanges > 4 {
                                let lastName = (result as NSString).substring(with: match.range(at: 4))
                                replacement += " \(lastName)"
                            }
                        }

                        result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
                        break  // Only process one sign-off pattern
                    }
                }
            }
        }

        return result
    }

    /// Unwraps artificial email line breaks (72-80 char wrapping) while preserving paragraph breaks
    /// Emails often contain hard line breaks at fixed widths for legacy compatibility.
    /// This function joins lines that were artificially wrapped while keeping intentional paragraph breaks.
    static func unwrapEmailLineBreaks(from text: String) -> String {
        // Normalize line endings: CRLF → LF, CR → LF
        var normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Normalize all special whitespace to regular space
        // This handles NBSP (U+00A0), thin space, em space, etc. that would otherwise
        // cause the lowercase check to fail when determining if lines should be joined
        let specialWhitespace: [Character] = [
            "\u{00A0}",  // Non-breaking space
            "\u{2002}",  // En space
            "\u{2003}",  // Em space
            "\u{2009}",  // Thin space
            "\u{200A}",  // Hair space
            "\u{202F}",  // Narrow no-break space
            "\u{205F}",  // Medium mathematical space
            "\u{3000}",  // Ideographic space
        ]
        for char in specialWhitespace {
            normalizedText = normalizedText.replacingOccurrences(of: String(char), with: " ")
        }

        let lines = normalizedText.components(separatedBy: "\n")
        guard lines.count > 1 else { return normalizedText }

        var result: [String] = []
        var currentParagraph = ""
        var i = 0

        while i < lines.count {
            let trimmedLine = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1

            // Skip empty lines but check if we should join across them
            if trimmedLine.isEmpty {
                if currentParagraph.isEmpty {
                    continue
                }

                // Look ahead to find the next non-empty line
                var nextNonEmptyIndex = i
                while nextNonEmptyIndex < lines.count &&
                      lines[nextNonEmptyIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                    nextNonEmptyIndex += 1
                }

                // Check if we should join across the blank line(s)
                if nextNonEmptyIndex < lines.count {
                    let nextLine = lines[nextNonEmptyIndex].trimmingCharacters(in: .whitespaces)
                    let lastChar = currentParagraph.last
                    let firstChar = nextLine.first

                    let endsWithPunctuation = lastChar.map { ".!?".contains($0) } ?? false
                    // Join unless next line starts with uppercase (new sentence)
                    let startsWithUppercase = firstChar?.isUppercase ?? false

                    if !endsWithPunctuation && !startsWithUppercase {
                        // This is a soft wrap across blank lines - skip the blanks and continue joining
                        continue
                    }
                }

                // Real paragraph break - flush current paragraph
                result.append(currentParagraph)
                result.append("") // Add paragraph separator
                currentParagraph = ""
                continue
            }

            if currentParagraph.isEmpty {
                currentParagraph = trimmedLine
            } else {
                // Check if this looks like a continuation (soft wrap) or new paragraph
                let lastChar = currentParagraph.last
                let firstChar = trimmedLine.first

                let endsWithPunctuation = lastChar.map { ".!?".contains($0) } ?? false
                // Join unless next line starts with uppercase (new sentence)
                let startsWithUppercase = firstChar?.isUppercase ?? false

                // Don't join if current line ends with colon (often precedes lists)
                let endsWithColon = lastChar == ":"

                // Don't join if next line looks like a list item
                // Handles: 1. 10. 100. a) A. - * • · (a) (1)
                let isListItem = TextProcessing.isListItem(trimmedLine)

                if !endsWithPunctuation && !endsWithColon && !startsWithUppercase && !isListItem {
                    // Join with space (unwrap soft line break)
                    currentParagraph += " " + trimmedLine
                } else {
                    // New paragraph
                    result.append(currentParagraph)
                    currentParagraph = trimmedLine
                }
            }
        }

        if !currentParagraph.isEmpty {
            result.append(currentParagraph)
        }

        // Filter out empty strings and join with double newlines for paragraph breaks
        let paragraphs = result.filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
