import Foundation
import WebKit
import UIKit

/// Main HTML sanitization service - facade delegating to specialized components
final class HTMLSanitizerService: HTMLSanitizerProtocol {
    static let shared = HTMLSanitizerService()

    // MARK: - Internal Components

    private let urlSanitizer = HTMLURLSanitizer()
    private let cssSanitizer = HTMLCSSSanitizer()
    private let trackingRemover = HTMLTrackingRemover()
    private let attributedConverter = HTMLAttributedStringConverter()
    private let complexityAnalyzer = HTMLComplexityAnalyzer()
    private let displayWrapper = HTMLDisplayWrapper()

    private init() {}

    // MARK: - Dangerous Tags Configuration

    private static let dangerousTags = [
        "script", "noscript", "object", "embed", "applet",
        "frame", "frameset", "iframe", "base", "basefont",
        "form", "input", "button", "select", "textarea",
        "option", "optgroup", "fieldset", "legend", "label",
        "meta", "link"
    ]

    // Pre-compiled regex patterns for dangerous tag removal (performance optimization)
    private static let compiledDangerousTagPatterns: [NSRegularExpression] = {
        dangerousTags.compactMap { RegexSanitizer.compileTagPattern($0) }
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

    // MARK: - Main Sanitization Method

    func sanitize(_ html: String) -> String {
        var sanitized = html

        // Remove dangerous elements (script, form, iframe, etc.) using pre-compiled patterns
        sanitized = removeDangerousElements(sanitized)

        // Note: We intentionally preserve <style> tags to keep responsive CSS/media queries
        // Marketing emails need these for proper mobile layouts

        // Remove event handlers
        sanitized = removeEventHandlers(sanitized)

        // Sanitize URLs (delegated)
        sanitized = urlSanitizer.sanitizeURLs(sanitized)

        // Remove tracking pixels (delegated)
        sanitized = trackingRemover.removeTrackingPixels(sanitized)

        // Sanitize CSS in both <style> tags and inline style attributes (delegated)
        sanitized = cssSanitizer.sanitizeStyles(sanitized)

        return sanitized
    }

    // MARK: - Specific Sanitization Methods

    private func removeDangerousElements(_ html: String) -> String {
        RegexSanitizer.removeTags(from: html, compiledPatterns: Self.compiledDangerousTagPatterns)
    }

    private func removeEventHandlers(_ html: String) -> String {
        RegexSanitizer.replace(in: html, regex: Self.eventHandlerRegex)
    }

    // MARK: - HTML to AttributedString Conversion

    func htmlToAttributedString(_ html: String, isFromMe: Bool) -> NSAttributedString? {
        let sanitized = sanitize(html)
        return attributedConverter.convert(sanitized, isFromMe: isFromMe)
    }

    // MARK: - HTML Complexity Analysis

    func analyzeComplexity(_ html: String) -> HTMLComplexity {
        complexityAnalyzer.analyze(html)
    }

    // MARK: - HTML Wrapping for Display

    func wrapHTMLForDisplay(_ html: String, isDarkMode: Bool) -> String {
        // Apply full sanitization first (URL sanitization, CSS sanitization, tracking pixel removal, etc.)
        let sanitized = sanitize(html)
        // Then wrap for display with styling
        return displayWrapper.wrapHTMLForDisplay(sanitized, isDarkMode: isDarkMode)
    }
}
