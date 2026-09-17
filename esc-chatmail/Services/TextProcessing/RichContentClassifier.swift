import Foundation

/// Decides whether an email's HTML is genuine rich content (newsletters,
/// receipts, transactional templates) that should render as an HTML preview,
/// rather than a personal message whose signature cruft merely looks rich.
enum RichContentClassifier {
    /// Runs the chat-bubble HTML cleanup chain first so quoted history and
    /// signatures do not count toward the classification.
    static func hasGenuineRichContentAfterCleanup(_ html: String) -> Bool {
        let cleanup = ChatBubbleTextProcessor.cleanedHTMLForProcessing(html)
        return hasGenuineRichContent(cleanup.html)
    }

    /// Determines if HTML contains genuine rich content (newsletters, receipts) vs personal email signature cruft
    /// Personal emails can have elaborate signatures (logo + headshot + 6-8 social icons + layout tables)
    /// Newsletters and marketing emails have many elements AND substantial text content
    static func hasGenuineRichContent(_ html: String) -> Bool {
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
    private static func isLikelyTransactionalOrMarketingContent(
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
    private static func stripAppleRichLinkPreviews(from html: String) -> String {
        var result = html
        var searchStart = result.startIndex

        // Remove every `<div ... class="apple-rich-link" ...>...</div>` block
        // (including nested divs). Each scan resumes from the removal point —
        // restarting from index 0 made k blocks cost k full passes over the
        // document (quadratic on crafted input). No REAL block's marker can
        // remain before the resume point (its enclosing div starts at or
        // before it and was just removed); the one thing not re-scanned is a
        // marker string fabricated by the removal joining surrounding text —
        // deliberately left alone, since it is inert text for this analysis
        // and the old restart-from-zero behavior would have deleted an
        // unrelated legitimate block for it.
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
    private static func findMatchingClosingDiv(in html: String, from start: String.Index) -> String.Index? {
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

    private static func approximateTextContent(from html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Counts HTML elements using efficient substring search
    /// Returns (imgCount, tableCount, cidCount, linkCount)
    private static func countHTMLElements(_ html: String) -> (Int, Int, Int, Int) {
        let imgCount = countOccurrences(of: "<img", in: html)
        let tableCount = countOccurrences(of: "<table", in: html)
        let cidCount = countOccurrences(of: "cid:", in: html)
        // Count <a> tags - need to check for both "<a " and "<a>" patterns
        let linkCountSpace = countOccurrences(of: "<a ", in: html)
        let linkCountDirect = countOccurrences(of: "<a>", in: html)

        return (imgCount, tableCount, cidCount, linkCountSpace + linkCountDirect)
    }

    /// Counts case-insensitive occurrences of a substring
    private static func countOccurrences(of substring: String, in string: String) -> Int {
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
    private static func isSimpleDivWrappedText(_ html: String, lowercased: String) -> Bool {

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
}
