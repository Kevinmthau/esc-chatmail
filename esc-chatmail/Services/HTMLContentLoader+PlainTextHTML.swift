import Foundation

// Plain-text → HTML conversion, link detection, and HTML escaping — a
// self-contained, instance-state-free layer the loader falls back to when a
// message has no usable HTML source. Normalizes raw plain text, converts it to
// a display fragment (quote folding + linkification), and provides the
// low-level HTML / attribute escapers. Also hosts prepareHTMLForDisplay, which
// applies quote/signature cleanup to existing HTML before it is wrapped.
extension HTMLContentLoader {

    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()
    private static let previewPaddingRegex: NSRegularExpression? = {
        // Some providers insert long runs of zero-width/nbsp padding to control inbox preview text.
        // Collapse these runs so fallback plain-text rendering does not appear as a blank page.
        try? NSRegularExpression(
            pattern: "[\\u200B\\u200C\\u200D\\uFEFF\\u00A0\\s]{40,}",
            options: []
        )
    }()

    private func normalizedPlainTextFallback(from text: String) -> String {
        var normalized = RawEmailSourceSanitizer.extractDisplayText(from: text)
        normalized = HTMLEntityDecoder.decode(normalized)

        if looksQuotedPrintable(normalized) {
            normalized = QuotedPrintableDecoder.decode(normalized)
            normalized = HTMLEntityDecoder.decode(normalized)
        }

        normalized = normalized
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")

        if let regex = Self.previewPaddingRegex {
            let range = NSRange(location: 0, length: normalized.utf16.count)
            normalized = regex.stringByReplacingMatches(in: normalized, options: [], range: range, withTemplate: " ")
        }

        normalized = normalized
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n[ \\t]+", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasMeaningfulPlainText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let nonWhitespace = text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return !nonWhitespace.isEmpty
    }

    func normalizedMeaningfulPlainText(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let normalized = normalizedPlainTextFallback(from: text)
        return hasMeaningfulPlainText(normalized) ? normalized : nil
    }

    private func looksQuotedPrintable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("=\r\n") ||
            lower.contains("=\n") ||
            lower.contains("=3d") ||
            lower.contains("=3c") ||
            lower.contains("=3e")
    }

    func prepareHTMLForDisplay(_ html: String, cleanupMode: HTMLContentCleanupMode) -> String {
        switch cleanupMode {
        case .none:
            return html
        case .quotedOnly:
            return HTMLCleanupFallback.cleanedHTML(from: html, modes: [.quotedOnly]).html
        case .quotedAndSignature:
            return HTMLCleanupFallback.cleanedHTML(from: html, modes: [.quotedAndSignatures, .quotedOnly]).html
        }
    }

    func convertPlainTextToHTML(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Match Apple Mail's default behavior: display the main content and collapse
        // quoted history behind a "See More" affordance.
        // Keep the sender's sign-off visible (signature removal is a chat-bubble concern).
        let extraction = PlainTextQuoteRemover.extractQuotes(from: normalized, removingSignature: false)
        let main = linkifyPlainTextForHTML(extraction.mainContent)

        let quotedHTML: String = extraction.quotedParts.map { part in
            let quote = linkifyPlainTextForHTML(part.text)
            let attribution = part.attribution.map { linkifyPlainTextForHTML($0) }

            // Keep nesting conservative; this is a display hint, not a full quote formatter.
            let level = max(0, min(part.nestingLevel, 3))
            let extraIndent = level > 0 ? "margin-left: \(level * 10)px;" : ""

            var block = ""
            if let attribution, !attribution.isEmpty {
                block += "<div class=\"esc-plain-quote-attr\">\(attribution)</div>"
            }
            block += "<blockquote class=\"esc-plain-quote\" style=\"\(extraIndent)\">\(quote)</blockquote>"
            return block
        }.joined(separator: "\n")

        // If there's no main content, don't hide everything behind "See More".
        let hasMainContent = !extraction.mainContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let detailsSection: String
        if !quotedHTML.isEmpty && hasMainContent {
            detailsSection = """
            <details class="esc-plain-details">
              <summary>See More</summary>
              <div class="esc-plain-quotes">
                \(quotedHTML)
              </div>
            </details>
            """
        } else if !quotedHTML.isEmpty {
            detailsSection = """
            <div class="esc-plain-quotes">
              \(quotedHTML)
            </div>
            """
        } else {
            detailsSection = ""
        }

        // Style block lives in the fragment so we can keep the wrapper logic generic.
        // (This fragment is sanitized and then wrapped into a full document by HTMLDisplayWrapper.)
        let styles = """
        <style id="esc-plain-text-styles">
          .esc-plain-main {
            white-space: pre-wrap;
            overflow-wrap: break-word;
            word-break: break-word;
            font-size: 17px;
            line-height: 1.45;
          }

          .esc-plain-details {
            margin-top: 14px;
          }

          .esc-plain-details > summary {
            list-style: none;
            color: #007AFF;
            font-size: 15px;
            font-weight: 500;
            user-select: none;
            -webkit-user-select: none;
          }

          .esc-plain-details > summary::-webkit-details-marker {
            display: none;
          }

          .esc-plain-quotes {
            margin-top: 10px;
          }

          .esc-plain-quote-attr {
            white-space: pre-wrap;
            overflow-wrap: break-word;
            word-break: break-word;
            font-size: 15px;
            line-height: 1.35;
            color: rgba(0, 0, 0, 0.6);
            margin: 0 0 6px 0;
          }

          .esc-plain-quote {
            white-space: pre-wrap;
            overflow-wrap: break-word;
            word-break: break-word;
            font-size: 15px;
            line-height: 1.35;
            margin: 0 0 10px 0;
            padding-left: 12px;
            border-left: 2px solid rgba(0, 0, 0, 0.18);
            color: rgba(0, 0, 0, 0.65);
          }

          @media (prefers-color-scheme: dark) {
            .esc-plain-quote-attr {
              color: rgba(255, 255, 255, 0.65);
            }
            .esc-plain-quote {
              border-left-color: rgba(255, 255, 255, 0.22);
              color: rgba(255, 255, 255, 0.70);
            }
          }
        </style>
        """

        return """
        \(styles)
        <div class="esc-plain-main">\(main)</div>
        \(detailsSection)
        """
    }

    private func linkifyPlainTextForHTML(_ text: String) -> String {
        guard let detector = Self.linkDetector else {
            return escapeHTML(text)
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = detector.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return escapeHTML(text)
        }

        var result = ""
        var currentLocation = 0

        for match in matches {
            let range = match.range
            guard range.location != NSNotFound, range.length > 0 else { continue }

            if range.location > currentLocation {
                let plainSegment = nsText.substring(with: NSRange(location: currentLocation, length: range.location - currentLocation))
                result += escapeHTML(plainSegment)
            }

            let matchedText = nsText.substring(with: range)
            if let detectedURL = match.url,
               let safeURL = normalizedLinkURL(detectedURL: detectedURL, originalText: matchedText) {
                result += "<a href=\"\(escapeHTMLAttribute(safeURL.absoluteString))\">\(escapeHTML(matchedText))</a>"
            } else {
                result += escapeHTML(matchedText)
            }

            currentLocation = range.location + range.length
        }

        if currentLocation < nsText.length {
            result += escapeHTML(nsText.substring(from: currentLocation))
        }

        return result
    }

    private func normalizedLinkURL(detectedURL: URL, originalText: String) -> URL? {
        if let scheme = detectedURL.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" else {
                return nil
            }
            return detectedURL
        }

        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("www."),
              let url = URL(string: "https://\(trimmed)") else {
            return nil
        }
        return url
    }

    private func escapeHTML(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeHTMLAttribute(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
