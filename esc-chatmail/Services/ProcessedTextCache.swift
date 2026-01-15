import Foundation

/// Thread-safe cache for processed message text content
/// Eliminates redundant HTML parsing and regex operations during scroll
/// Uses LRUCacheActor for automatic eviction management
actor ProcessedTextCache {
    static let shared = ProcessedTextCache()

    /// Cached text content with rich content indicator
    struct CachedText: Sendable {
        let plainText: String?
        let hasRichContent: Bool
    }

    private let cache: LRUCacheActor<String, CachedText>

    /// Track active prefetch task to prevent unbounded task accumulation
    private var activePrefetchTask: Task<Void, Never>?

    /// Maximum number of messages to process in a single prefetch batch
    private let maxPrefetchBatchSize = 20

    init() {
        self.cache = LRUCacheActor(config: CacheConfiguration(
            maxItems: CacheConfig.textCacheSize,
            maxMemoryBytes: CacheConfig.textCacheMaxBytes,
            ttlSeconds: nil,
            evictionPolicy: .lru
        ))
    }

    /// Estimates memory size of a cached text entry
    private static func estimateSize(_ plainText: String?, _ hasRichContent: Bool) -> Int {
        // String size: UTF-8 bytes + some overhead
        let textSize = (plainText?.utf8.count ?? 0)
        // Bool size + struct overhead
        let overheadSize = 24
        return textSize + overheadSize
    }

    func get(messageId: String) async -> (plainText: String?, hasRichContent: Bool)? {
        guard let entry = await cache.get(messageId) else { return nil }
        return (entry.plainText, entry.hasRichContent)
    }

    func set(messageId: String, plainText: String?, hasRichContent: Bool) async {
        let size = Self.estimateSize(plainText, hasRichContent)
        await cache.set(messageId, value: CachedText(plainText: plainText, hasRichContent: hasRichContent), sizeBytes: size)
    }

    func prefetch(messageIds: [String]) async {
        // Filter out already cached messages
        var uncachedIds: [String] = []
        for messageId in messageIds {
            if await !cache.contains(messageId) {
                uncachedIds.append(messageId)
            }
        }
        guard !uncachedIds.isEmpty else { return }

        // Limit batch size to prevent processing too many at once
        let idsToProcess = Array(uncachedIds.prefix(maxPrefetchBatchSize))

        // Cancel any existing prefetch task to prevent accumulation during rapid scroll
        activePrefetchTask?.cancel()

        // Track the new prefetch task
        activePrefetchTask = Task.detached(priority: .utility) { [weak self, idsToProcess] in
            let handler = HTMLContentHandler.shared

            for messageId in idsToProcess {
                // Check for cancellation between messages
                guard !Task.isCancelled else { break }

                let result = ProcessedTextCache.processMessage(messageId: messageId, handler: handler)
                await self?.set(messageId: messageId, plainText: result.plainText, hasRichContent: result.hasRichContent)
            }
        }
    }

    /// Cancel any active prefetch task (call when view disappears)
    func cancelPrefetch() {
        activePrefetchTask?.cancel()
        activePrefetchTask = nil
    }

    /// Process a single message - can be called from background thread
    nonisolated static func processMessage(messageId: String, handler: HTMLContentHandler) -> (plainText: String?, hasRichContent: Bool) {
        var plainText: String?
        var hasRichContent = false

        if handler.htmlFileExists(for: messageId),
           let html = handler.loadHTML(for: messageId) {
            // Strip quoted content from HTML first
            let cleanedHTML = HTMLQuoteRemover.removeQuotes(from: html) ?? html

            let extracted = TextProcessing.extractPlainText(from: cleanedHTML)
            if !extracted.isEmpty {
                let unwrapped = TextProcessing.unwrapEmailLineBreaks(from: extracted)
                plainText = TextProcessing.stripQuotedText(from: unwrapped)
            }

            // Check for rich content in cleaned HTML only (not quoted sections)
            let lowercased = cleanedHTML.lowercased()
            hasRichContent = lowercased.contains("<table") ||
                            lowercased.contains("<img") ||
                            lowercased.contains("<video") ||
                            lowercased.contains("<iframe")
        }

        return (plainText, hasRichContent)
    }

    func clear() async {
        await cache.clear()
    }

    /// Returns cache statistics for monitoring
    func getStatistics() async -> LRUCacheStatistics {
        await cache.getStatistics()
    }
}

// MARK: - Text Processing Helpers (nonisolated for background thread usage)
enum TextProcessing {
    static func extractPlainText(from html: String) -> String {
        var text = html

        // Remove script and style tags and their content
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression, range: nil)

        // Convert consecutive <br> tags to paragraph breaks, single <br> to space (soft wrap)
        // First: <br><br> or <br>\s*<br> → paragraph break
        text = text.replacingOccurrences(of: "<br[^>]*>\\s*<br[^>]*>", with: "\n\n", options: .regularExpression, range: nil)
        // Then: remaining single <br> → space (for soft line wrapping)
        text = text.replacingOccurrences(of: "<br[^>]*>", with: " ", options: .regularExpression, range: nil)

        // Paragraphs and headings get double newlines (actual content breaks)
        text = text.replacingOccurrences(of: "</p>", with: "\n\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "</h[1-6]>", with: "\n\n", options: .regularExpression, range: nil)

        // Remove all HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)

        // Decode HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
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

                if !endsWithPunctuation && !startsWithUppercase {
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
