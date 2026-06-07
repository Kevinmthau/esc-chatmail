import Foundation

/// Main HTML sanitization service - facade delegating to specialized components
final class HTMLSanitizerService {
    static let shared = HTMLSanitizerService()

    // MARK: - Internal Components

    private let urlSanitizer = HTMLURLSanitizer()
    private let cssSanitizer = HTMLCSSSanitizer()
    private let trackingRemover = HTMLTrackingRemover()
    private let displayWrapper = HTMLDisplayWrapper()
    private let dangerousMarkupSanitizer: (String) throws -> String
    private let originalReaderActiveMarkupSanitizer: (String) throws -> String

    // MARK: - Dangerous Tags Configuration

    private static let dangerousTags = EmailDOMHTMLSanitizer.dangerousTags
    private static let originalReaderActiveMarkupTags = EmailDOMHTMLSanitizer.originalReaderActiveMarkupTags

    // Pre-compiled regex patterns for dangerous tag removal (performance optimization)
    private static let compiledDangerousTagPatterns: [NSRegularExpression] = {
        dangerousTags.compactMap { RegexSanitizer.compileTagPattern($0) }
    }()
    private static let compiledOriginalReaderActiveMarkupPatterns: [NSRegularExpression] = {
        originalReaderActiveMarkupTags.compactMap { RegexSanitizer.compileTagPattern($0) }
    }()

    // swiftlint:disable:next force_try
    private static let originalReaderUnwrappedTagRegex: NSRegularExpression = {
        let tagPattern = EmailDOMHTMLSanitizer.originalReaderUnwrappedTags.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "</?(?:\(tagPattern))\\b[^>]*>",
            options: .caseInsensitive
        )
    }()
    // swiftlint:disable:next force_try
    private static let originalReaderEscapedTextTagRegex: NSRegularExpression = {
        let tagPattern = EmailDOMHTMLSanitizer.originalReaderEscapedTextTags.joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "<(\(tagPattern))\\b[^>]*>(.*?)</\\1>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
    }()

    // Pre-compiled event handler removal pattern
    // swiftlint:disable:next force_try
    private static let eventHandlerRegex: NSRegularExpression = {
        try! NSRegularExpression(
            // Require leading whitespace so we only strip HTML attributes (e.g. ` onload=...`)
            // and do not corrupt URL path segments like `/cdn-cgi/image/onerror=redirect,...`.
            pattern: "\\s+on\\w+\\s*=\\s*[\"'][^\"']*[\"']|\\s+on\\w+\\s*=\\s*[^\\s>]+",
            options: .caseInsensitive
        )
    }()

    init(
        dangerousMarkupSanitizer: @escaping (String) throws -> String =
            EmailDOMHTMLSanitizer.removeDangerousElementsAndEventHandlers,
        originalReaderActiveMarkupSanitizer: @escaping (String) throws -> String =
            EmailDOMHTMLSanitizer.removeOriginalReaderActiveMarkupAndEventHandlers
    ) {
        self.dangerousMarkupSanitizer = dangerousMarkupSanitizer
        self.originalReaderActiveMarkupSanitizer = originalReaderActiveMarkupSanitizer
    }

    // MARK: - Main Sanitization Method

    func sanitize(_ html: String) -> String {
        sanitize(html, rewriteModernImageFormatHints: true)
    }

    func sanitize(_ html: String, rewriteModernImageFormatHints: Bool) -> String {
        var sanitized = removeDangerousElementsAndEventHandlers(html)

        // Sanitize URLs (delegated)
        sanitized = urlSanitizer.sanitizeURLs(
            sanitized,
            rewriteModernFormatQueryHints: rewriteModernImageFormatHints
        )

        // Remove tracking pixels (delegated)
        sanitized = trackingRemover.removeTrackingPixels(sanitized)

        // Sanitize CSS in both <style> tags and inline style attributes (delegated)
        sanitized = cssSanitizer.sanitizeStyles(sanitized)

        return sanitized
    }

    // MARK: - Specific Sanitization Methods

    private func removeDangerousElementsAndEventHandlers(_ html: String) -> String {
        do {
            return try dangerousMarkupSanitizer(html)
        } catch {
            return removeDangerousElementsAndEventHandlersWithLegacyRegex(html)
        }
    }

    func removeOriginalReaderActiveMarkupAndEventHandlers(_ html: String) -> String {
        do {
            return try originalReaderActiveMarkupSanitizer(html)
        } catch {
            return removeOriginalReaderActiveMarkupAndEventHandlersWithLegacyRegex(html)
        }
    }

    private func removeDangerousElementsAndEventHandlersWithLegacyRegex(_ html: String) -> String {
        var sanitized = html

        // Remove dangerous elements (script, form, iframe, etc.) using pre-compiled patterns.
        sanitized = removeDangerousElements(sanitized)

        // Note: We intentionally preserve <style> tags to keep responsive CSS/media queries.
        // Marketing emails need these for proper mobile layouts.

        sanitized = removeEventHandlers(sanitized)
        return sanitized
    }

    private func removeOriginalReaderActiveMarkupAndEventHandlersWithLegacyRegex(_ html: String) -> String {
        var sanitized = html

        sanitized = replaceOriginalReaderEscapedTextTagsWithLegacyRegex(sanitized)
        sanitized = RegexSanitizer.removeTags(
            from: sanitized,
            compiledPatterns: Self.compiledOriginalReaderActiveMarkupPatterns
        )
        sanitized = RegexSanitizer.replace(in: sanitized, regex: Self.originalReaderUnwrappedTagRegex)
        sanitized = removeEventHandlers(sanitized)
        return sanitized
    }

    private func removeDangerousElements(_ html: String) -> String {
        RegexSanitizer.removeTags(from: html, compiledPatterns: Self.compiledDangerousTagPatterns)
    }

    private func removeEventHandlers(_ html: String) -> String {
        RegexSanitizer.replace(in: html, regex: Self.eventHandlerRegex)
    }

    private func replaceOriginalReaderEscapedTextTagsWithLegacyRegex(_ html: String) -> String {
        let matches = Self.originalReaderEscapedTextTagRegex.matches(
            in: html,
            options: [],
            range: NSRange(location: 0, length: html.utf16.count)
        )
        guard !matches.isEmpty else { return html }

        var result = ""
        var currentIndex = html.startIndex
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: html),
                  let contentRange = Range(match.range(at: 2), in: html) else {
                return html
            }

            result.append(contentsOf: html[currentIndex..<fullRange.lowerBound])
            result.append(Self.escapeHTML(HTMLEntityDecoder.decode(String(html[contentRange]))))
            currentIndex = fullRange.upperBound
        }
        result.append(contentsOf: html[currentIndex...])
        return result
    }

    private static func escapeHTML(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - HTML Wrapping for Display

    func wrapHTMLForDisplay(
        _ html: String,
        isDarkMode: Bool,
        displayPurpose: HTMLDisplayPurpose = .preview
    ) -> String {
        // Apply full sanitization first (URL sanitization, CSS sanitization, tracking pixel removal, etc.)
        let sanitized = sanitize(html)
        // Then wrap for display with styling
        return displayWrapper.wrapHTMLForDisplay(
            sanitized,
            isDarkMode: isDarkMode,
            displayPurpose: displayPurpose
        )
    }

    /// Wraps already-sanitized HTML for display without re-sanitizing.
    /// Use this when the caller has already applied sanitize() to avoid
    /// redundant regex passes that can corrupt complex newsletter HTML.
    func wrapSanitizedHTMLForDisplay(
        _ html: String,
        isDarkMode: Bool,
        displayPurpose: HTMLDisplayPurpose = .preview,
        headSerialization: HTMLHeadInjectionSerialization = .domPreferred
    ) -> String {
        displayWrapper.wrapHTMLForDisplay(
            html,
            isDarkMode: isDarkMode,
            displayPurpose: displayPurpose,
            headSerialization: headSerialization
        )
    }
}
