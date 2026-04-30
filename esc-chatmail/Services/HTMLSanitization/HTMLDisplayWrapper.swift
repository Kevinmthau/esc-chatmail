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

    private struct LayoutSelectorTarget {
        let tagName: String?
        let id: String?
        let classNames: Set<String>
        let classAttributeValue: String?
        let exactClassAttributeValues: Set<String>

        init(
            tagName: String?,
            id: String?,
            classNames: Set<String>,
            classAttributeValue: String? = nil,
            exactClassAttributeValues: Set<String> = []
        ) {
            self.tagName = tagName
            self.id = id
            self.classNames = classNames
            self.classAttributeValue = classAttributeValue
            self.exactClassAttributeValues = exactClassAttributeValues
        }
    }

    private enum LayoutSelectorCombinator {
        case descendant
        case child
    }

    private struct LayoutSelectorPart {
        let target: LayoutSelectorTarget
        let previousCombinator: LayoutSelectorCombinator?
    }

    private struct HTMLSelectorElement {
        let target: LayoutSelectorTarget
        let ancestors: [LayoutSelectorTarget]
    }

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
                return #"<meta name="viewport" content="width=\#(fixedWidth), user-scalable=yes">"#
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
        let containsResponsiveWidthQuery = containsResponsiveScreenWidthMediaQuery(in: liveHTML)

        let layoutCSSHTML = removingConditionalCSSMediaBlocks(
            from: liveHTML,
            preservingUnconditionalScreenMedia: !containsResponsiveWidthQuery
        )

        let candidates = [
            largestLayoutWidth(in: liveHTML, pattern: #"<table[^>]*?\bwidth\s*=\s*["']?([0-9]{3,4})"#),
            largestLayoutWidth(in: layoutCSSHTML, pattern: #"(?:^|[;{"'=])\s*width\s*:\s*([0-9]{3,4})\s*px"#),
            largestLayoutWidth(in: layoutCSSHTML, pattern: #"(?:^|[;{"'=])\s*min-width\s*:\s*([0-9]{3,4})\s*px"#)
        ].compactMap { $0 }

        guard let fixedWidth = candidates.max() else {
            return nil
        }

        if containsResponsiveWidthQuery,
           containsResponsiveFluidLayoutOverride(
               in: liveHTML,
               layoutCSSHTML: layoutCSSHTML,
               fixedWidth: fixedWidth
           ) {
            return nil
        }

        return fixedWidth
    }

    private func containsResponsiveFluidLayoutOverride(
        in html: String,
        layoutCSSHTML: String,
        fixedWidth: Int
    ) -> Bool {
        let fixedLayoutTargets = fixedLayoutSelectorTargets(
            in: html,
            layoutCSSHTML: layoutCSSHTML,
            fixedWidth: fixedWidth
        )
        guard !fixedLayoutTargets.isEmpty else {
            return false
        }

        var searchStart = html.startIndex

        while let mediaRange = html.range(
            of: "@media",
            options: .caseInsensitive,
            range: searchStart..<html.endIndex
        ) {
            guard let blockStart = html[mediaRange.upperBound...].firstIndex(of: "{"),
                  let blockEnd = matchingClosingBrace(in: html, openingBrace: blockStart) else {
                searchStart = mediaRange.upperBound
                continue
            }

            let mediaPrelude = html[mediaRange.upperBound..<blockStart]
            let queries = mediaPrelude.split(separator: ",", omittingEmptySubsequences: true)
            if queries.contains(where: isResponsiveScreenWidthMediaQuery) {
                let blockBody = String(html[html.index(after: blockStart)..<blockEnd])
                if containsFluidWidthDeclaration(in: blockBody, targeting: fixedLayoutTargets) {
                    return true
                }
            }

            searchStart = html.index(after: blockEnd)
        }

        return false
    }

    private func fixedLayoutSelectorTargets(
        in html: String,
        layoutCSSHTML: String,
        fixedWidth: Int
    ) -> [LayoutSelectorTarget] {
        let fixedTableTargets = fixedTableSelectorTargets(in: html, fixedWidth: fixedWidth)
        if !fixedTableTargets.isEmpty {
            return fixedTableTargets
        }

        return fixedInlineStyleSelectorTargets(in: html, fixedWidth: fixedWidth)
            + fixedCSSSelectorTargets(in: layoutCSSHTML, fixedWidth: fixedWidth)
    }

    private func fixedTableSelectorTargets(in html: String, fixedWidth: Int) -> [LayoutSelectorTarget] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<table\b(?=[^>]*?\bwidth\s*=\s*["']?\#(fixedWidth)(?:["'\s>]|[^0-9]))[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let tagRange = Range(match.range(at: 0), in: html) else {
                return nil
            }

            return htmlElementSelectorTarget(tagName: "table", tagHTML: String(html[tagRange]))
        }
    }

    private func fixedInlineStyleSelectorTargets(in html: String, fixedWidth: Int) -> [LayoutSelectorTarget] {
        guard let tagRegex = try? NSRegularExpression(
            pattern: #"<([A-Za-z][A-Za-z0-9:-]*)\b(?=[^>]*?\bstyle\s*=)[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ),
        let widthRegex = try? NSRegularExpression(
            pattern: #"(?<!-)\b(?:width|min-width)\s*:\s*\#(fixedWidth)\s*px\b"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return tagRegex.matches(in: html, range: range).compactMap { match in
            guard let tagNameRange = Range(match.range(at: 1), in: html),
                  let tagRange = Range(match.range(at: 0), in: html) else {
                return nil
            }

            let tagHTML = String(html[tagRange])
            guard let style = attributeValue(named: "style", in: tagHTML) else {
                return nil
            }

            let styleRange = NSRange(style.startIndex..<style.endIndex, in: style)
            guard widthRegex.firstMatch(in: style, range: styleRange) != nil else {
                return nil
            }

            return htmlElementSelectorTarget(tagName: String(html[tagNameRange]), tagHTML: tagHTML)
        }
    }

    private func fixedCSSSelectorTargets(in html: String, fixedWidth: Int) -> [LayoutSelectorTarget] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([^{}@]+)\{[^{}]*(?<!-)\b(?:width|min-width)\s*:\s*\#(fixedWidth)\s*px\b"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let selectorElements = htmlSelectorElements(in: html)
        let elementTargets = selectorElements.map(\.target)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).flatMap { match -> [LayoutSelectorTarget] in
            guard let selectorsRange = Range(match.range(at: 1), in: html) else {
                return []
            }

            return String(html[selectorsRange]).split(separator: ",").flatMap { selector -> [LayoutSelectorTarget] in
                let selector = cssSelectorText(from: String(selector))
                guard let target = selectorTarget(in: selector) else {
                    return []
                }
                guard !selectorContainsCombinator(selector) else {
                    guard let matchingElements = htmlElementSelectorTargets(
                        matchingComplexSelector: selector,
                        in: selectorElements
                    ) else {
                        return [target]
                    }
                    return matchingElements.isEmpty ? [target] : matchingElements
                }

                let matchingElements = elementTargets.filter { elementTarget in
                    selectorTarget(target, matches: elementTarget)
                }
                return matchingElements.isEmpty ? [target] : matchingElements
            }
        }
    }

    private func htmlSelectorElements(in html: String) -> [HTMLSelectorElement] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<\s*(/)?\s*([A-Za-z][A-Za-z0-9:-]*)\b[^>]*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        var elements: [HTMLSelectorElement] = []
        var stack: [LayoutSelectorTarget] = []
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, range: range) {
            guard let tagNameRange = Range(match.range(at: 2), in: html),
                  let tagRange = Range(match.range(at: 0), in: html) else {
                continue
            }

            let tagHTML = String(html[tagRange])
            let tagName = String(html[tagNameRange]).lowercased()
            if Range(match.range(at: 1), in: html) != nil {
                if let index = stack.lastIndex(where: { $0.tagName == tagName }) {
                    stack.removeSubrange(index...)
                }
                continue
            }

            let elementTarget = htmlElementSelectorTarget(
                tagName: tagName,
                tagHTML: tagHTML
            )
            elements.append(HTMLSelectorElement(target: elementTarget, ancestors: stack))

            if !isSelfClosingHTMLElement(tagName: tagName, tagHTML: tagHTML) {
                stack.append(elementTarget)
            }
        }

        return elements
    }

    private func containsFluidWidthDeclaration(
        in css: String,
        targeting fixedLayoutTargets: [LayoutSelectorTarget]
    ) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"([^{}@]+)\{[^{}]*(?<!-)\bwidth\s*:\s*100\s*%"#,
            options: [.caseInsensitive]
        ) else {
            return false
        }

        let range = NSRange(css.startIndex..<css.endIndex, in: css)
        return regex.matches(in: css, range: range).contains { match in
            guard let selectorsRange = Range(match.range(at: 1), in: css) else {
                return false
            }

            return selectorTargets(in: String(css[selectorsRange])).contains { target in
                fixedLayoutTargets.contains { fixedTarget in
                    selectorTarget(target, matches: fixedTarget)
                }
            }
        }
    }

    private func selectorTarget(
        _ target: LayoutSelectorTarget,
        matches fixedTarget: LayoutSelectorTarget
    ) -> Bool {
        if let targetTagName = target.tagName,
           let fixedTagName = fixedTarget.tagName,
           targetTagName != fixedTagName {
            return false
        }

        if let targetID = target.id {
            guard fixedTarget.id == targetID else {
                return false
            }
        }

        for classAttributeValue in target.exactClassAttributeValues {
            guard exactClassAttributeValue(classAttributeValue, matches: fixedTarget) else {
                return false
            }
        }

        guard target.classNames.isSubset(of: fixedTarget.classNames) else {
            return false
        }

        if target.id != nil || !target.classNames.isEmpty || !target.exactClassAttributeValues.isEmpty {
            return true
        }

        return target.tagName != nil && fixedTarget.tagName == target.tagName
    }

    private func cssSelectorText(from capturedSelector: String) -> String {
        let selector = capturedSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let styleRange = selector.range(of: "<style", options: [.caseInsensitive, .backwards]),
              let tagEnd = selector[styleRange.lowerBound...].firstIndex(of: ">") else {
            return selector
        }

        return String(selector[selector.index(after: tagEnd)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectorContainsCombinator(_ selector: String) -> Bool {
        var previousOutsideAttributeWasWhitespace = false
        var isInsideAttributeSelector = false
        var quoteCharacter: Character?

        for character in selector {
            if let activeQuote = quoteCharacter {
                if character == activeQuote {
                    quoteCharacter = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                quoteCharacter = character
                continue
            }

            if character == "[" {
                isInsideAttributeSelector = true
                previousOutsideAttributeWasWhitespace = false
                continue
            }

            if character == "]" {
                isInsideAttributeSelector = false
                previousOutsideAttributeWasWhitespace = false
                continue
            }

            guard !isInsideAttributeSelector else {
                continue
            }

            if character == ">" || character == "+" || character == "~" {
                return true
            }

            if character.isWhitespace {
                previousOutsideAttributeWasWhitespace = true
                continue
            }

            if previousOutsideAttributeWasWhitespace {
                return true
            }
            previousOutsideAttributeWasWhitespace = false
        }

        return false
    }

    private func htmlElementSelectorTargets(
        matchingComplexSelector selector: String,
        in elements: [HTMLSelectorElement]
    ) -> [LayoutSelectorTarget]? {
        guard let selectorParts = complexSelectorParts(in: selector), selectorParts.count > 1 else {
            return nil
        }

        return elements.compactMap { element in
            htmlSelectorElement(element, matches: selectorParts) ? element.target : nil
        }
    }

    private func htmlSelectorElement(
        _ element: HTMLSelectorElement,
        matches selectorParts: [LayoutSelectorPart]
    ) -> Bool {
        guard let lastPart = selectorParts.last,
              selectorTarget(lastPart.target, matches: element.target) else {
            return false
        }

        var ancestorEndIndex = element.ancestors.count
        for partIndex in stride(from: selectorParts.count - 2, through: 0, by: -1) {
            let part = selectorParts[partIndex]
            let combinator = selectorParts[partIndex + 1].previousCombinator ?? .descendant

            switch combinator {
            case .child:
                guard ancestorEndIndex > 0 else {
                    return false
                }

                let parentIndex = ancestorEndIndex - 1
                guard selectorTarget(part.target, matches: element.ancestors[parentIndex]) else {
                    return false
                }
                ancestorEndIndex = parentIndex

            case .descendant:
                guard let ancestorIndex = matchingAncestorIndex(
                    for: part.target,
                    before: ancestorEndIndex,
                    in: element.ancestors
                ) else {
                    return false
                }
                ancestorEndIndex = ancestorIndex
            }
        }

        return true
    }

    private func matchingAncestorIndex(
        for target: LayoutSelectorTarget,
        before endIndex: Int,
        in ancestors: [LayoutSelectorTarget]
    ) -> Int? {
        guard endIndex > 0 else {
            return nil
        }

        for index in stride(from: endIndex - 1, through: 0, by: -1) {
            if selectorTarget(target, matches: ancestors[index]) {
                return index
            }
        }

        return nil
    }

    private func complexSelectorParts(in selector: String) -> [LayoutSelectorPart]? {
        var parts: [LayoutSelectorPart] = []
        var current = ""
        var pendingCombinator: LayoutSelectorCombinator?
        var hasWhitespaceAfterCurrent = false
        var isInsideAttributeSelector = false
        var parenthesisDepth = 0
        var quoteCharacter: Character?

        func appendCurrentPart() -> Bool {
            let compound = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current.removeAll(keepingCapacity: true)
            guard !compound.isEmpty else {
                return true
            }
            guard let target = selectorTarget(in: compound) else {
                return false
            }

            parts.append(LayoutSelectorPart(
                target: target,
                previousCombinator: parts.isEmpty ? nil : pendingCombinator ?? .descendant
            ))
            pendingCombinator = nil
            return true
        }

        for character in selector {
            if let activeQuote = quoteCharacter {
                current.append(character)
                if character == activeQuote {
                    quoteCharacter = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                current.append(character)
                quoteCharacter = character
                continue
            }

            if character == "[" {
                current.append(character)
                isInsideAttributeSelector = true
                continue
            }

            if character == "]" {
                current.append(character)
                isInsideAttributeSelector = false
                continue
            }

            if !isInsideAttributeSelector {
                if character == "(" {
                    parenthesisDepth += 1
                    current.append(character)
                    continue
                }

                if character == ")" {
                    parenthesisDepth = max(0, parenthesisDepth - 1)
                    current.append(character)
                    continue
                }
            }

            if isInsideAttributeSelector || parenthesisDepth > 0 {
                current.append(character)
                continue
            }

            if character == "+" || character == "~" {
                return nil
            }

            if character == ">" {
                guard appendCurrentPart() else {
                    return nil
                }
                pendingCombinator = .child
                hasWhitespaceAfterCurrent = false
                continue
            }

            if character.isWhitespace {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasWhitespaceAfterCurrent = true
                }
                continue
            }

            if hasWhitespaceAfterCurrent {
                guard appendCurrentPart() else {
                    return nil
                }
                pendingCombinator = .descendant
                hasWhitespaceAfterCurrent = false
            }

            current.append(character)
        }

        guard appendCurrentPart() else {
            return nil
        }

        return parts
    }

    private func isSelfClosingHTMLElement(tagName: String, tagHTML: String) -> Bool {
        let voidElementNames: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
            "meta", "param", "source", "track", "wbr"
        ]

        return voidElementNames.contains(tagName)
            || tagHTML.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/>")
    }

    private func exactClassAttributeValue(
        _ classAttributeValue: String,
        matches fixedTarget: LayoutSelectorTarget
    ) -> Bool {
        if fixedTarget.classAttributeValue == classAttributeValue
            || fixedTarget.exactClassAttributeValues.contains(classAttributeValue) {
            return true
        }

        let exactClassNames = Set(classAttributeValue.split { $0.isWhitespace }.map(String.init))
        return !exactClassNames.isEmpty
            && fixedTarget.classAttributeValue == nil
            && fixedTarget.exactClassAttributeValues.isEmpty
            && fixedTarget.classNames == exactClassNames
    }

    private func selectorTargets(in selectors: String) -> [LayoutSelectorTarget] {
        selectors.split(separator: ",").compactMap { selector in
            selectorTarget(in: String(selector))
        }
    }

    private func selectorTarget(in selector: String) -> LayoutSelectorTarget? {
        let compound = selector
            .replacingOccurrences(of: ">", with: " ")
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "~", with: " ")
            .split { $0.isWhitespace }
            .last
            .map(String.init) ?? selector

        let tagName = firstRegexCapture(
            in: compound,
            pattern: #"^(?:[A-Za-z_][A-Za-z0-9_-]*\|)?([A-Za-z][A-Za-z0-9_-]*)"#
        )?.lowercased()
        let id = firstRegexCapture(in: compound, pattern: #"#([A-Za-z_][A-Za-z0-9_-]*)"#)
        let exactClassAttributeValues = Set(classAttributeSelectorValues(in: compound))
        let classNames = Set(regexCaptures(in: compound, pattern: #"\.([A-Za-z_][A-Za-z0-9_-]*)"#)
            + exactClassAttributeValues.flatMap { $0.split { $0.isWhitespace }.map(String.init) })

        guard tagName != nil || id != nil || !classNames.isEmpty || !exactClassAttributeValues.isEmpty else {
            return nil
        }

        return LayoutSelectorTarget(
            tagName: tagName,
            id: id,
            classNames: classNames,
            exactClassAttributeValues: exactClassAttributeValues
        )
    }

    private func htmlElementSelectorTarget(tagName: String, tagHTML: String) -> LayoutSelectorTarget {
        let id = attributeValue(named: "id", in: tagHTML)
        let classAttributeValue = attributeValue(named: "class", in: tagHTML)
        let classNames = Set(
            classAttributeValue?
                .split { $0.isWhitespace }
                .map(String.init) ?? []
        )

        return LayoutSelectorTarget(
            tagName: tagName.lowercased(),
            id: id,
            classNames: classNames,
            classAttributeValue: classAttributeValue
        )
    }

    private func classAttributeSelectorValues(in selector: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[\s*class\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\]\s]+))\s*(?:[iIsS])?\]"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(selector.startIndex..<selector.endIndex, in: selector)
        return regex.matches(in: selector, range: range).flatMap { match -> [String] in
            for index in 1..<match.numberOfRanges {
                guard let valueRange = Range(match.range(at: index), in: selector) else {
                    continue
                }

                return [String(selector[valueRange])]
            }

            return []
        }
    }

    private func attributeValue(named name: String, in tagHTML: String) -> String? {
        let pattern = #"\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(tagHTML.startIndex..<tagHTML.endIndex, in: tagHTML)
        guard let match = regex.firstMatch(in: tagHTML, range: range) else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            guard let valueRange = Range(match.range(at: index), in: tagHTML) else {
                continue
            }

            return String(tagHTML[valueRange])
        }

        return nil
    }

    private func firstRegexCapture(in text: String, pattern: String) -> String? {
        regexCaptures(in: text, pattern: pattern).first
    }

    private func regexCaptures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                return nil
            }

            return String(text[valueRange])
        }
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

    private func removingConditionalCSSMediaBlocks(
        from html: String,
        preservingUnconditionalScreenMedia: Bool = true
    ) -> String {
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
            guard !preservingUnconditionalScreenMedia || shouldIgnoreCSSMediaBlock(with: mediaPrelude) else {
                searchStart = result.index(after: blockStart)
                continue
            }

            let removalEnd = result.index(after: blockEnd)
            result.removeSubrange(mediaRange.lowerBound..<removalEnd)
            searchStart = mediaRange.lowerBound
        }

        return result
    }

    private func containsResponsiveScreenWidthMediaQuery(in html: String) -> Bool {
        var searchStart = html.startIndex

        while let mediaRange = html.range(
            of: "@media",
            options: .caseInsensitive,
            range: searchStart..<html.endIndex
        ) {
            guard let blockStart = html[mediaRange.upperBound...].firstIndex(of: "{"),
                  let blockEnd = matchingClosingBrace(in: html, openingBrace: blockStart) else {
                searchStart = mediaRange.upperBound
                continue
            }

            let mediaPrelude = html[mediaRange.upperBound..<blockStart]
            let queries = mediaPrelude.split(separator: ",", omittingEmptySubsequences: true)
            if queries.contains(where: isResponsiveScreenWidthMediaQuery) {
                return true
            }

            searchStart = html.index(after: blockEnd)
        }

        return false
    }

    private func isResponsiveScreenWidthMediaQuery(_ query: Substring) -> Bool {
        let normalized = String(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty,
              !normalized.contains("not"),
              normalized.contains("max-width") || normalized.contains("max-device-width") else {
            return false
        }

        let mediaTypePrelude = normalized
            .split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false)
            .first ?? ""
        let mediaTypes = mediaTypePrelude
            .split { $0.isWhitespace }
            .filter { $0 != "only" && $0 != "and" }

        return mediaTypes.isEmpty || mediaTypes.contains("screen") || mediaTypes.contains("all")
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
