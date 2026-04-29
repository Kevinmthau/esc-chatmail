import Foundation

enum HTMLDisplayPurpose: String, CaseIterable, Sendable {
    case preview
    case original
}

/// Wraps HTML content for display in WebView with proper styling and security
/// Designed to match Apple Mail's rendering behavior as closely as possible
struct HTMLDisplayWrapper {
    private static let appleMailFallbackFontStack = "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Helvetica, Arial, sans-serif"
    private static let minimumFixedLayoutViewportWidth = 376
    private static let maximumFixedLayoutViewportWidth = 900

    private struct RootTypographyDetector {
        // swiftlint:disable:next force_try
        private static let rootElementTagRegex = try! NSRegularExpression(
            pattern: #"<(html|body)\b([^>]*)>"#,
            options: .caseInsensitive
        )

        // swiftlint:disable:next force_try
        private static let styleAttributeRegex = try! NSRegularExpression(
            pattern: #"\bstyle\s*=\s*(?:"([\s\S]*?)"|'([\s\S]*?)')"#,
            options: .caseInsensitive
        )

        // swiftlint:disable:next force_try
        private static let styleTagRegex = try! NSRegularExpression(
            pattern: #"<style\b[^>]*>([\s\S]*?)</style>"#,
            options: .caseInsensitive
        )

        // swiftlint:disable:next force_try
        private static let rootTypeSelectorRegex = try! NSRegularExpression(
            pattern: #"^(?:[A-Za-z_][A-Za-z0-9_-]*\|)?(?:html|body)(?=$|[.#\[:])"#,
            options: .caseInsensitive
        )

        static func containsAuthoredTypography(in html: String) -> Bool {
            containsRootInlineTypography(in: html) || containsRootStylesheetTypography(in: html)
        }

        private static func containsRootInlineTypography(in html: String) -> Bool {
            let range = NSRange(html.startIndex..., in: html)
            let matches = rootElementTagRegex.matches(in: html, range: range)

            for match in matches {
                guard let attributesRange = Range(match.range(at: 2), in: html) else {
                    continue
                }

                let attributes = String(html[attributesRange])
                if let inlineStyle = styleAttribute(in: attributes),
                   containsTypographyDeclaration(in: inlineStyle) {
                    return true
                }
            }

            return false
        }

        private static func containsRootStylesheetTypography(in html: String) -> Bool {
            let range = NSRange(html.startIndex..., in: html)
            let matches = styleTagRegex.matches(in: html, range: range)

            for match in matches {
                guard let cssRange = Range(match.range(at: 1), in: html) else {
                    continue
                }

                let css = stripComments(from: String(html[cssRange]))
                if containsRootTypographyRule(in: css) {
                    return true
                }
            }

            return false
        }

        private static func styleAttribute(in attributes: String) -> String? {
            let range = NSRange(attributes.startIndex..., in: attributes)
            guard let match = styleAttributeRegex.firstMatch(in: attributes, range: range) else {
                return nil
            }

            if let doubleQuotedRange = Range(match.range(at: 1), in: attributes) {
                return String(attributes[doubleQuotedRange])
            }

            if let singleQuotedRange = Range(match.range(at: 2), in: attributes) {
                return String(attributes[singleQuotedRange])
            }

            return nil
        }

        private static func containsRootTypographyRule(in css: String) -> Bool {
            var currentIndex = css.startIndex

            while let block = nextCSSBlock(in: css, from: currentIndex) {
                let prelude = block.prelude.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prelude.isEmpty {
                    if prelude.hasPrefix("@") {
                        if nextCSSBlock(in: block.body, from: block.body.startIndex) != nil,
                           containsRootTypographyRule(in: block.body) {
                            return true
                        }
                    } else if selectorsTargetRoot(prelude),
                              containsTypographyDeclaration(in: block.body) {
                        return true
                    }
                }

                currentIndex = block.nextIndex
            }

            return false
        }

        private static func selectorsTargetRoot(_ selectors: String) -> Bool {
            splitTopLevel(selectors, on: ",").contains { selector in
                let compound = lastCompoundSelector(in: selector)
                return compoundTargetsRoot(compound)
            }
        }

        private static func compoundTargetsRoot(_ compound: String) -> Bool {
            let trimmed = compound.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return false
            }

            // Pseudo-elements do not set typography on the root element itself.
            guard !trimmed.contains("::") else {
                return false
            }

            let lowercased = trimmed.lowercased()
            if lowercased.hasPrefix(":root") || lowercased.hasPrefix("*:root") {
                return true
            }

            let range = NSRange(trimmed.startIndex..., in: trimmed)
            return rootTypeSelectorRegex.firstMatch(in: trimmed, range: range) != nil
        }

        private static func containsTypographyDeclaration(in declarations: String) -> Bool {
            splitTopLevel(declarations, on: ";").contains { declaration in
                guard let separatorIndex = firstTopLevelColon(in: declaration) else {
                    return false
                }

                let property = declaration[..<separatorIndex]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let value = declaration[declaration.index(after: separatorIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !value.isEmpty else {
                    return false
                }

                return property == "font" || property == "font-family"
            }
        }

        private static func splitTopLevel(_ text: String, on separator: Character) -> [String] {
            var segments: [String] = []
            var segmentStart = text.startIndex
            var index = text.startIndex
            var quoteCharacter: Character?
            var parenthesesDepth = 0
            var bracketDepth = 0

            while index < text.endIndex {
                let character = text[index]

                if let activeQuote = quoteCharacter {
                    if character == "\\" {
                        index = text.index(after: index)
                    } else if character == activeQuote {
                        quoteCharacter = nil
                    }
                } else {
                    switch character {
                    case "\"", "'":
                        quoteCharacter = character
                    case "(":
                        parenthesesDepth += 1
                    case ")":
                        parenthesesDepth = max(0, parenthesesDepth - 1)
                    case "[":
                        bracketDepth += 1
                    case "]":
                        bracketDepth = max(0, bracketDepth - 1)
                    default:
                        if character == separator && parenthesesDepth == 0 && bracketDepth == 0 {
                            segments.append(String(text[segmentStart..<index]))
                            segmentStart = text.index(after: index)
                        }
                    }
                }

                index = text.index(after: index)
            }

            segments.append(String(text[segmentStart...]))
            return segments
        }

        private static func firstTopLevelColon(in text: String) -> String.Index? {
            var index = text.startIndex
            var quoteCharacter: Character?
            var parenthesesDepth = 0
            var bracketDepth = 0

            while index < text.endIndex {
                let character = text[index]

                if let activeQuote = quoteCharacter {
                    if character == "\\" {
                        index = text.index(after: index)
                    } else if character == activeQuote {
                        quoteCharacter = nil
                    }
                } else {
                    switch character {
                    case "\"", "'":
                        quoteCharacter = character
                    case "(":
                        parenthesesDepth += 1
                    case ")":
                        parenthesesDepth = max(0, parenthesesDepth - 1)
                    case "[":
                        bracketDepth += 1
                    case "]":
                        bracketDepth = max(0, bracketDepth - 1)
                    case ":" where parenthesesDepth == 0 && bracketDepth == 0:
                        return index
                    default:
                        break
                    }
                }

                index = text.index(after: index)
            }

            return nil
        }

        private static func lastCompoundSelector(in selector: String) -> String {
            var compounds: [String] = []
            var current = ""
            var index = selector.startIndex
            var quoteCharacter: Character?
            var parenthesesDepth = 0
            var bracketDepth = 0

            while index < selector.endIndex {
                let character = selector[index]

                if let activeQuote = quoteCharacter {
                    current.append(character)

                    if character == "\\" {
                        index = selector.index(after: index)
                        if index < selector.endIndex {
                            current.append(selector[index])
                        }
                    } else if character == activeQuote {
                        quoteCharacter = nil
                    }
                } else {
                    switch character {
                    case "\"", "'":
                        quoteCharacter = character
                        current.append(character)
                    case "(":
                        parenthesesDepth += 1
                        current.append(character)
                    case ")":
                        parenthesesDepth = max(0, parenthesesDepth - 1)
                        current.append(character)
                    case "[":
                        bracketDepth += 1
                        current.append(character)
                    case "]":
                        bracketDepth = max(0, bracketDepth - 1)
                        current.append(character)
                    default:
                        if (character == ">" || character == "+" || character == "~")
                            && parenthesesDepth == 0
                            && bracketDepth == 0 {
                            flushSelectorCompound(&compounds, current: &current)
                        } else if character.isWhitespace && parenthesesDepth == 0 && bracketDepth == 0 {
                            flushSelectorCompound(&compounds, current: &current)
                        } else {
                            current.append(character)
                        }
                    }
                }

                index = selector.index(after: index)
            }

            flushSelectorCompound(&compounds, current: &current)
            return compounds.last ?? selector
        }

        private static func flushSelectorCompound(_ compounds: inout [String], current: inout String) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                compounds.append(trimmed)
            }
            current.removeAll(keepingCapacity: true)
        }

        private static func stripComments(from css: String) -> String {
            var result = ""
            var index = css.startIndex
            var quoteCharacter: Character?

            while index < css.endIndex {
                let character = css[index]

                if let activeQuote = quoteCharacter {
                    result.append(character)
                    if character == "\\" {
                        index = css.index(after: index)
                        if index < css.endIndex {
                            result.append(css[index])
                        }
                    } else if character == activeQuote {
                        quoteCharacter = nil
                    }
                    index = css.index(after: index)
                    continue
                }

                if character == "/" {
                    let nextIndex = css.index(after: index)
                    if nextIndex < css.endIndex && css[nextIndex] == "*" {
                        index = css.index(after: nextIndex)
                        while index < css.endIndex {
                            if css[index] == "*" {
                                let possibleEnd = css.index(after: index)
                                if possibleEnd < css.endIndex && css[possibleEnd] == "/" {
                                    index = css.index(after: possibleEnd)
                                    break
                                }
                            }
                            index = css.index(after: index)
                        }
                        continue
                    }
                }

                if character == "\"" || character == "'" {
                    quoteCharacter = character
                }

                result.append(character)
                index = css.index(after: index)
            }

            return result
        }

        private static func nextCSSBlock(
            in css: String,
            from startIndex: String.Index
        ) -> (prelude: String, body: String, nextIndex: String.Index)? {
            var index = startIndex
            var quoteCharacter: Character?
            var braceDepth = 0
            let preludeStart = startIndex
            var preludeEnd: String.Index?
            var blockStart: String.Index?

            while index < css.endIndex {
                let character = css[index]

                if let activeQuote = quoteCharacter {
                    if character == "\\" {
                        index = css.index(after: index)
                    } else if character == activeQuote {
                        quoteCharacter = nil
                    }
                } else {
                    switch character {
                    case "\"", "'":
                        quoteCharacter = character
                    case "{":
                        if braceDepth == 0 {
                            preludeEnd = index
                            blockStart = css.index(after: index)
                        }
                        braceDepth += 1
                    case "}":
                        guard braceDepth > 0, let blockStart else {
                            break
                        }

                        braceDepth -= 1
                        if braceDepth == 0, let preludeEnd {
                            let prelude = String(css[preludeStart..<preludeEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                            let body = String(css[blockStart..<index])
                            return (prelude, body, css.index(after: index))
                        }
                    default:
                        break
                    }
                }

                index = css.index(after: index)
            }

            return nil
        }
    }

    struct Theme: Equatable, Sendable {
        let backgroundColorHex: String
        let textColorHex: String
    }

    static func theme(
        isDarkMode: Bool,
        displayPurpose: HTMLDisplayPurpose
    ) -> Theme {
        switch (displayPurpose, isDarkMode) {
        case (.preview, false):
            return Theme(backgroundColorHex: "#f2f2f7", textColorHex: "#000000")
        case (.preview, true):
            return Theme(backgroundColorHex: "#1c1c1e", textColorHex: "#ffffff")
        case (.original, false):
            return Theme(backgroundColorHex: "#ffffff", textColorHex: "#000000")
        case (.original, true):
            // Full-message rendering should preserve authored colors instead of forcing
            // the document onto a dark surface that many emails were never designed for.
            return Theme(backgroundColorHex: "#ffffff", textColorHex: "#000000")
        }
    }

    /// Wraps HTML content with full HTML document structure and styling
    /// Note: HTML should already be sanitized by HTMLSanitizerService.sanitize() before calling this
    func wrapHTMLForDisplay(
        _ html: String,
        isDarkMode: Bool,
        displayPurpose: HTMLDisplayPurpose = .preview
    ) -> String {
        // Content is pre-sanitized by HTMLSanitizerService, so we just wrap it
        let sanitized = html
        let theme = Self.theme(isDarkMode: isDarkMode, displayPurpose: displayPurpose)
        let fallbackTypographyCSS = originalFallbackTypographyCSSIfNeeded(
            for: sanitized,
            displayPurpose: displayPurpose
        )

        // Check if HTML already has a complete document structure
        let hasDoctype = html.lowercased().contains("<!doctype")
        let hasHtmlTag = html.lowercased().contains("<html")

        // If the email already has a full HTML structure, inject our styles minimally
        if hasDoctype || hasHtmlTag {
            return wrapExistingDocument(
                sanitized,
                isDarkMode: isDarkMode,
                theme: theme,
                displayPurpose: displayPurpose,
                fallbackTypographyCSS: fallbackTypographyCSS
            )
        }

        // For partial HTML (no document structure), wrap with our template
        return wrapPartialHTML(
            sanitized,
            isDarkMode: isDarkMode,
            theme: theme,
            displayPurpose: displayPurpose,
            fallbackTypographyCSS: fallbackTypographyCSS
        )
    }

    /// Wraps HTML that already has document structure - inject styles without breaking existing layout
    private func wrapExistingDocument(
        _ html: String,
        isDarkMode: Bool,
        theme: Theme,
        displayPurpose: HTMLDisplayPurpose,
        fallbackTypographyCSS: String
    ) -> String {
        // Inject our viewport meta, CSP, and minimal styles into the existing document
        // This preserves the email's original <style> tags and media queries

        let shouldApplyDarkModeFallbackText = isDarkMode && displayPurpose == .preview
        let originalColorSchemeHead = colorSchemeHead(for: displayPurpose)
        let originalColorSchemeCSS = colorSchemeCSS(for: displayPurpose)
        let viewportMetaTag = viewportMetaTag(for: displayPurpose, html: html)

        let injectedHead = """
        \(viewportMetaTag)
        \(originalColorSchemeHead)
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none';">
        <style id="esc-mail-styles">
            /* Minimal resets - don't override email's own styles */
            html {
                -webkit-text-size-adjust: 100%;
                background-color: \(theme.backgroundColorHex);
                \(originalColorSchemeCSS)
            }
            body {
                margin: 0;
                padding: 8px;
                background-color: \(theme.backgroundColorHex);
                \(fallbackTypographyCSS)
            }
            /* Only constrain images that would overflow */
            img {
                max-width: 100%;
                height: auto;
            }
            /* Allow tables to shrink but don't force width */
            table {
                max-width: 100%;
            }
            \(linkCSS(for: displayPurpose))
            \(shouldApplyDarkModeFallbackText ? darkModeCSS(textColor: theme.textColorHex) : "")
        </style>
        """

        var result = html

        // Try to inject after existing <head> tag
        if let headRange = result.range(of: "<head>", options: .caseInsensitive) {
            result.insert(contentsOf: "\n" + injectedHead + "\n", at: headRange.upperBound)
        } else if let headRange = result.range(of: "<head ", options: .caseInsensitive) {
            // Handle <head ...> with attributes
            if let closingBracket = result[headRange.upperBound...].range(of: ">") {
                result.insert(contentsOf: "\n" + injectedHead + "\n", at: closingBracket.upperBound)
            }
        } else if let htmlRange = result.range(of: "<html>", options: .caseInsensitive) {
            // No head tag, inject after <html>
            result.insert(contentsOf: "\n<head>\n" + injectedHead + "\n</head>\n", at: htmlRange.upperBound)
        } else if let htmlRange = result.range(of: "<html ", options: .caseInsensitive) {
            if let closingBracket = result[htmlRange.upperBound...].range(of: ">") {
                result.insert(contentsOf: "\n<head>\n" + injectedHead + "\n</head>\n", at: closingBracket.upperBound)
            }
        }

        // Ensure we have a proper doctype
        if !result.lowercased().contains("<!doctype") {
            result = "<!DOCTYPE html>\n" + result
        }

        return result
    }

    /// Wraps partial HTML (no document structure) with our full template
    private func wrapPartialHTML(
        _ html: String,
        isDarkMode: Bool,
        theme: Theme,
        displayPurpose: HTMLDisplayPurpose,
        fallbackTypographyCSS: String
    ) -> String {
        let shouldApplyDarkModeFallbackText = isDarkMode && displayPurpose == .preview
        let originalColorSchemeHead = colorSchemeHead(for: displayPurpose)
        let originalColorSchemeCSS = colorSchemeCSS(for: displayPurpose)
        let viewportMetaTag = viewportMetaTag(for: displayPurpose, html: html)

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            \(viewportMetaTag)
            \(originalColorSchemeHead)
            <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; frame-src 'none';">
            <style>
                * {
                    box-sizing: border-box;
                }
                html {
                    -webkit-text-size-adjust: 100%;
                    background-color: \(theme.backgroundColorHex);
                    \(originalColorSchemeCSS)
                }
                body {
                    color: \(theme.textColorHex);
                    background-color: \(theme.backgroundColorHex);
                    padding: 8px;
                    margin: 0;
                    word-wrap: break-word;
                    \(fallbackTypographyCSS)
                }
                /* Constrain images without breaking layout */
                img {
                    max-width: 100%;
                    height: auto;
                    border: 0;
                }
                /* Allow tables to shrink but preserve intentional widths */
                table {
                    max-width: 100%;
                    border-collapse: collapse;
                }
                \(linkCSS(for: displayPurpose))
                /* Text wrapping */
                div, td, th, p {
                    overflow-wrap: break-word;
                    word-break: break-word;
                }
                td, th {
                    vertical-align: top;
                }
                \(shouldApplyDarkModeFallbackText ? darkModeCSS(textColor: theme.textColorHex) : "")
            </style>
        </head>
        <body>
            \(html)
        </body>
        </html>
        """
    }

    private func originalFallbackTypographyCSSIfNeeded(
        for html: String,
        displayPurpose: HTMLDisplayPurpose
    ) -> String {
        guard shouldApplyOriginalFallbackTypography(to: html, displayPurpose: displayPurpose) else {
            return ""
        }

        // Fragment-style emails often omit any font declaration and rely on the mail client's
        // default body typography. Match Apple Mail more closely here instead of falling back
        // to WKWebView's default serif font.
        return """
        font-family: \(Self.appleMailFallbackFontStack);
        """
    }

    private func shouldApplyOriginalFallbackTypography(
        to html: String,
        displayPurpose: HTMLDisplayPurpose
    ) -> Bool {
        guard displayPurpose == .original else {
            return false
        }

        return !documentDefinesOriginalTypography(in: html)
    }

    private func documentDefinesOriginalTypography(in html: String) -> Bool {
        RootTypographyDetector.containsAuthoredTypography(in: html)
    }

    private func colorSchemeHead(for displayPurpose: HTMLDisplayPurpose) -> String {
        guard displayPurpose == .original else {
            return ""
        }

        return """
        <meta name="color-scheme" content="light">
        <meta name="supported-color-schemes" content="light">
        """
    }

    private func colorSchemeCSS(for displayPurpose: HTMLDisplayPurpose) -> String {
        guard displayPurpose == .original else {
            return ""
        }

        return "color-scheme: light;"
    }

    private func viewportMetaTag(for displayPurpose: HTMLDisplayPurpose, html: String) -> String {
        switch displayPurpose {
        case .preview:
            return #"<meta name="viewport" content="width=device-width, initial-scale=1.0, shrink-to-fit=no, user-scalable=yes">"#
        case .original:
            // Some marketing emails still rely on WebKit's initial shrink-to-fit behavior for
            // legacy fixed-width sections that intentionally do not stack on mobile.
            if let fixedWidth = originalFixedLayoutViewportWidth(in: html) {
                return #"<meta name="viewport" content="width=\#(fixedWidth), initial-scale=1.0, user-scalable=yes">"#
            }
            return #"<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=yes">"#
        }
    }

    private func originalFixedLayoutViewportWidth(in html: String) -> Int? {
        let normalizedHTML = html
            .replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")
            .replacingOccurrences(of: "=3D", with: "=", options: .caseInsensitive)
        let liveHTML = removingHTMLComments(from: normalizedHTML)
        let layoutCSSHTML = removingConditionalCSSMediaBlocks(from: liveHTML)

        let candidates = [
            largestLayoutWidth(in: liveHTML, pattern: #"<table[^>]*?\bwidth\s*=\s*["']?([0-9]{3,4})"#),
            largestLayoutWidth(in: layoutCSSHTML, pattern: #"(?:^|[;{"'=])\s*width\s*:\s*([0-9]{3,4})\s*px"#),
            largestLayoutWidth(in: layoutCSSHTML, pattern: #"(?:^|[;{"'=])\s*min-width\s*:\s*([0-9]{3,4})\s*px"#)
        ].compactMap { $0 }

        return candidates.max()
    }

    private func removingHTMLComments(from html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<!--[\s\S]*?-->"#,
            options: []
        ) else {
            return html
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    private func removingConditionalCSSMediaBlocks(from html: String) -> String {
        var result = html
        var searchStart = result.startIndex

        while let mediaRange = result.range(
            of: "@media",
            options: .caseInsensitive,
            range: searchStart..<result.endIndex
        ) {
            guard let blockStart = result[mediaRange.upperBound...].firstIndex(of: "{"),
                  let blockEnd = matchingClosingBrace(in: result, openingBrace: blockStart) else {
                searchStart = mediaRange.upperBound
                continue
            }

            let mediaPrelude = result[mediaRange.upperBound..<blockStart]
            guard shouldIgnoreCSSMediaBlock(with: mediaPrelude) else {
                searchStart = result.index(after: blockStart)
                continue
            }

            let removalEnd = result.index(after: blockEnd)
            result.removeSubrange(mediaRange.lowerBound..<removalEnd)
            searchStart = mediaRange.lowerBound
        }

        return result
    }

    private func shouldIgnoreCSSMediaBlock(with prelude: Substring) -> Bool {
        let queries = prelude.split(separator: ",", omittingEmptySubsequences: true)
        guard !queries.isEmpty else {
            return true
        }

        return !queries.contains { isUnconditionallyApplicableScreenMediaQuery($0) }
    }

    private func isUnconditionallyApplicableScreenMediaQuery(_ query: Substring) -> Bool {
        let normalized = String(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty,
              !normalized.contains("(") else {
            return false
        }

        let tokens = normalized.split { $0.isWhitespace }.map(String.init)
        guard !tokens.contains("not") else {
            return false
        }

        let mediaTypes = tokens.filter { $0 != "only" && $0 != "and" }
        return mediaTypes.count == 1 && (mediaTypes[0] == "screen" || mediaTypes[0] == "all")
    }

    private func matchingClosingBrace(in text: String, openingBrace: String.Index) -> String.Index? {
        var index = openingBrace
        var depth = 0
        var quoteCharacter: Character?

        while index < text.endIndex {
            let character = text[index]

            if let activeQuote = quoteCharacter {
                if character == "\\" {
                    let escapedIndex = text.index(after: index)
                    guard escapedIndex < text.endIndex else {
                        return nil
                    }
                    index = escapedIndex
                } else if character == activeQuote {
                    quoteCharacter = nil
                }
            } else {
                switch character {
                case "\"", "'":
                    quoteCharacter = character
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return index
                    }
                default:
                    break
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    private func largestLayoutWidth(in html: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match -> Int? in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: html),
                  let width = Int(html[valueRange]),
                  width >= Self.minimumFixedLayoutViewportWidth,
                  width <= Self.maximumFixedLayoutViewportWidth else {
                return nil
            }

            return width
        }.max()
    }

    private func linkCSS(for displayPurpose: HTMLDisplayPurpose) -> String {
        guard displayPurpose == .preview else {
            return ""
        }

        return """
        /* Preview cards should inherit surrounding text styling. */
        a {
            color: inherit;
            text-decoration: inherit;
        }
        """
    }

    /// Dark mode CSS overrides - only applied when email doesn't specify colors
    private func darkModeCSS(textColor: String) -> String {
        return """
        /* Dark mode: only override text color if not already specified */
        p:not([style*="color"]),
        span:not([style*="color"]),
        div:not([style*="color"]),
        td:not([style*="color"]),
        th:not([style*="color"]),
        li:not([style*="color"]) {
            color: \(textColor);
        }
        """
    }
}
