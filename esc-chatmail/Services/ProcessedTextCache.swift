import Foundation

/// Thread-safe cache for processed message text content
/// Eliminates redundant HTML parsing and regex operations during scroll
actor ProcessedTextCache {
    static let shared = ProcessedTextCache()

    private var cache: [String: CachedText] = [:]
    private let maxCacheSize = 500

    private struct CachedText {
        let plainText: String?
        let hasRichContent: Bool
        let accessedAt: Date
    }

    func get(messageId: String) -> (plainText: String?, hasRichContent: Bool)? {
        guard var entry = cache[messageId] else { return nil }
        // Update access time for LRU
        entry = CachedText(plainText: entry.plainText, hasRichContent: entry.hasRichContent, accessedAt: Date())
        cache[messageId] = entry
        return (entry.plainText, entry.hasRichContent)
    }

    func set(messageId: String, plainText: String?, hasRichContent: Bool) {
        // Evict old entries if cache is full
        if cache.count >= maxCacheSize {
            evictOldEntries()
        }
        cache[messageId] = CachedText(plainText: plainText, hasRichContent: hasRichContent, accessedAt: Date())
    }

    func prefetch(messageIds: [String]) async {
        // Process messages that aren't cached yet
        let uncachedIds = messageIds.filter { cache[$0] == nil }
        guard !uncachedIds.isEmpty else { return }

        // Process in batches on background thread
        await Task.detached(priority: .utility) { [uncachedIds] in
            let handler = HTMLContentHandler.shared

            for messageId in uncachedIds {
                let result = Self.processMessage(messageId: messageId, handler: handler)
                await self.set(messageId: messageId, plainText: result.plainText, hasRichContent: result.hasRichContent)
            }
        }.value
    }

    /// Process a single message - can be called from background thread
    nonisolated static func processMessage(messageId: String, handler: HTMLContentHandler) -> (plainText: String?, hasRichContent: Bool) {
        var plainText: String?
        var hasRichContent = false

        if handler.htmlFileExists(for: messageId),
           let html = handler.loadHTML(for: messageId) {
            let extracted = TextProcessing.extractPlainText(from: html)
            if !extracted.isEmpty {
                plainText = TextProcessing.stripQuotedText(from: extracted)
            }

            // Check for rich content
            let lowercased = html.lowercased()
            hasRichContent = lowercased.contains("<table") ||
                            lowercased.contains("<video") ||
                            lowercased.contains("<iframe")
        }

        return (plainText, hasRichContent)
    }

    private func evictOldEntries() {
        // Remove oldest 20% of entries
        let sortedKeys = cache.keys.sorted { key1, key2 in
            (cache[key1]?.accessedAt ?? .distantPast) < (cache[key2]?.accessedAt ?? .distantPast)
        }
        let toRemove = sortedKeys.prefix(maxCacheSize / 5)
        for key in toRemove {
            cache.removeValue(forKey: key)
        }
    }

    func clear() {
        cache.removeAll()
    }
}

// MARK: - Text Processing Helpers (nonisolated for background thread usage)
enum TextProcessing {
    static func extractPlainText(from html: String) -> String {
        var text = html

        // Remove script and style tags and their content
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression, range: nil)

        // Convert explicit line breaks to newlines
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression, range: nil)

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
        text = text.replacingOccurrences(of: " ?\\n ?", with: "\n", options: .regularExpression, range: nil)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression, range: nil)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    static func stripQuotedText(from text: String) -> String {
        var normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Use regex for efficient multiple newline collapse instead of while loop
        normalizedText = normalizedText.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        let lines = normalizedText.components(separatedBy: "\n")
        var newMessageLines: [String] = []
        var lastLineWasEmpty = false

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Stop at common quoted text markers
            if trimmedLine.starts(with: ">") ||
               (trimmedLine.starts(with: "On ") && trimmedLine.contains("wrote:")) ||
               (trimmedLine.starts(with: "From:") && index > 0) ||
               trimmedLine == "..." ||
               trimmedLine.contains("---------- Forwarded message ---------") ||
               trimmedLine.contains("________________________________") {
                break
            }

            // Skip consecutive empty lines
            let isEmptyLine = trimmedLine.isEmpty
            if isEmptyLine && lastLineWasEmpty {
                continue
            }
            lastLineWasEmpty = isEmptyLine

            newMessageLines.append(trimmedLine.isEmpty ? "" : line)
        }

        return newMessageLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
