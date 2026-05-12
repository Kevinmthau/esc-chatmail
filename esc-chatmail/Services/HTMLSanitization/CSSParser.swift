import Foundation

struct CSSSelectorSpecificity: Comparable {
    let idCount: Int
    let classLikeCount: Int
    let elementCount: Int

    static func < (lhs: CSSSelectorSpecificity, rhs: CSSSelectorSpecificity) -> Bool {
        if lhs.idCount != rhs.idCount {
            return lhs.idCount < rhs.idCount
        }
        if lhs.classLikeCount != rhs.classLikeCount {
            return lhs.classLikeCount < rhs.classLikeCount
        }
        return lhs.elementCount < rhs.elementCount
    }
}

struct CSSMediaWidthRange {
    let minimum: Int?
    let maximum: Int?

    static var responsiveLayoutViewport: CSSMediaWidthRange {
        CSSMediaWidthRange(
            minimum: HTMLDisplayWrapper.minimumFixedLayoutViewportWidth,
            maximum: HTMLDisplayWrapper.maximumResponsiveLayoutViewportWidth
        )
    }

    func intersection(with other: CSSMediaWidthRange) -> CSSMediaWidthRange? {
        let minimum = [minimum, other.minimum].compactMap { $0 }.max()
        let maximum = [maximum, other.maximum].compactMap { $0 }.min()
        if let minimum, let maximum, minimum > maximum {
            return nil
        }

        return CSSMediaWidthRange(minimum: minimum, maximum: maximum)
    }

    func canMatchResponsiveLayoutViewport() -> Bool {
        responsiveLayoutViewportSpan() != nil
    }

    func contains(_ width: Int) -> Bool {
        if let minimum, width < minimum {
            return false
        }
        if let maximum, width > maximum {
            return false
        }
        return true
    }

    func responsiveLayoutViewportSpan() -> ClosedRange<Int>? {
        let lowerBound = max(minimum ?? 0, HTMLDisplayWrapper.minimumFixedLayoutViewportWidth)
        let upperBound = min(maximum ?? Int.max, HTMLDisplayWrapper.maximumResponsiveLayoutViewportWidth)
        guard lowerBound <= upperBound else {
            return nil
        }

        return lowerBound...upperBound
    }
}

enum RootTypographyDetector {
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

enum CSSParser {
    static func nextCSSBlock(
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
                        let prelude = String(css[preludeStart..<preludeEnd])
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

    static func matchingClosingBrace(in text: String, openingBrace: String.Index) -> String.Index? {
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

    static func cssSelectorText(from capturedSelector: String) -> String {
        let selector = capturedSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let styleRange = selector.range(of: "<style", options: [.caseInsensitive, .backwards]),
              let tagEnd = selector[styleRange.lowerBound...].firstIndex(of: ">") else {
            return selector
        }

        return String(selector[selector.index(after: tagEnd)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cssSelectorSpecificity(in selector: String) -> CSSSelectorSpecificity {
        let sanitizedSelector = removingSelectorPseudoElementSuffixes(from: selector)
        let idCount = regexMatchCount(in: sanitizedSelector, pattern: #"#([A-Za-z_][A-Za-z0-9_-]*)"#)
        let classLikeCount =
            regexMatchCount(in: sanitizedSelector, pattern: #"\.([A-Za-z_][A-Za-z0-9_-]*)"#)
            + regexMatchCount(in: sanitizedSelector, pattern: #"\[[^\]]+\]"#)
            + regexMatchCount(in: sanitizedSelector, pattern: #":(?!:)[A-Za-z_-][A-Za-z0-9_-]*(?:\([^)]*\))?"#)
        let elementCount = regexMatchCount(
            in: sanitizedSelector,
            pattern: #"(?:(?<=^)|(?<=[\s>+~]))(?:[A-Za-z_][A-Za-z0-9_-]*\|)?[A-Za-z][A-Za-z0-9_-]*(?=$|[#.\[:\s>+~])"#
        )

        return CSSSelectorSpecificity(
            idCount: idCount,
            classLikeCount: classLikeCount,
            elementCount: elementCount
        )
    }

    static func removingSelectorPseudoElementSuffixes(from selector: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"::[A-Za-z_-][A-Za-z0-9_-]*(?:\([^)]*\))?"#,
            options: []
        ) else {
            return selector
        }

        let range = NSRange(selector.startIndex..<selector.endIndex, in: selector)
        return regex.stringByReplacingMatches(in: selector, range: range, withTemplate: "")
    }

    static func removingConditionalCSSMediaBlocks(
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

    static func containsResponsiveScreenWidthMediaQuery(in html: String) -> Bool {
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

    static func isResponsiveScreenWidthMediaQuery(_ query: Substring) -> Bool {
        let normalized = String(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaQueryTargetsScreen(normalized),
              normalized.contains("max-width") || normalized.contains("max-device-width") else {
            return false
        }

        return true
    }

    static func screenMediaQueryWidthRange(_ query: Substring) -> CSSMediaWidthRange? {
        let normalized = String(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaQueryTargetsScreen(normalized) else {
            return nil
        }

        var minimum: Int?
        var maximum: Int?
        var foundWidthConstraint = false

        if let widthBoundRegex = try? NSRegularExpression(
            pattern: #"\(\s*(min|max)-(?:device-)?width\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*(px|em|rem)\s*\)"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            for match in widthBoundRegex.matches(in: normalized, range: range) {
                guard let boundRange = Range(match.range(at: 1), in: normalized),
                      let widthRange = Range(match.range(at: 2), in: normalized),
                      let unitRange = Range(match.range(at: 3), in: normalized) else {
                    continue
                }

                let isMinimum = String(normalized[boundRange]) == "min"
                guard let width = mediaQueryWidthPixels(
                    from: normalized[widthRange],
                    unit: normalized[unitRange],
                    isMinimum: isMinimum
                ) else {
                    continue
                }

                foundWidthConstraint = true
                if isMinimum {
                    minimum = max(minimum ?? width, width)
                } else {
                    maximum = min(maximum ?? width, width)
                }
            }
        }

        if let exactWidthRegex = try? NSRegularExpression(
            pattern: #"\(\s*(?:device-)?width\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*(px|em|rem)\s*\)"#,
            options: [.caseInsensitive]
        ) {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            for match in exactWidthRegex.matches(in: normalized, range: range) {
                guard let widthRange = Range(match.range(at: 1), in: normalized),
                      let unitRange = Range(match.range(at: 2), in: normalized),
                      let minimumWidth = mediaQueryWidthPixels(
                        from: normalized[widthRange],
                        unit: normalized[unitRange],
                        isMinimum: true
                      ),
                      let maximumWidth = mediaQueryWidthPixels(
                        from: normalized[widthRange],
                        unit: normalized[unitRange],
                        isMinimum: false
                      ) else {
                    continue
                }

                foundWidthConstraint = true
                minimum = max(minimum ?? minimumWidth, minimumWidth)
                maximum = min(maximum ?? maximumWidth, maximumWidth)
            }
        }

        guard foundWidthConstraint || isUnconditionallyApplicableScreenMediaQuery(query) else {
            return nil
        }

        if let minimum, let maximum, minimum > maximum {
            return nil
        }

        return CSSMediaWidthRange(minimum: minimum, maximum: maximum)
    }

    static func mediaQueryWidthPixels(
        from value: Substring,
        unit: Substring,
        isMinimum: Bool
    ) -> Int? {
        guard let numericValue = Double(value) else {
            return nil
        }

        let multiplier: Double
        switch String(unit) {
        case "px":
            multiplier = 1.0
        case "em", "rem":
            multiplier = 16.0
        default:
            return nil
        }

        let pixelValue = numericValue * multiplier
        guard pixelValue.isFinite else {
            return nil
        }

        let boundedPixelValue = min(pixelValue, Double(HTMLDisplayWrapper.maximumFixedLayoutViewportWidth))
        return isMinimum ? Int(ceil(boundedPixelValue)) : Int(floor(boundedPixelValue))
    }

    static func mediaQueryTargetsScreen(_ normalized: String) -> Bool {
        guard !normalized.isEmpty,
              !normalized.contains("not") else {
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

    static func shouldIgnoreCSSMediaBlock(with prelude: Substring) -> Bool {
        let queries = prelude.split(separator: ",", omittingEmptySubsequences: true)
        guard !queries.isEmpty else {
            return true
        }

        return !queries.contains { isUnconditionallyApplicableScreenMediaQuery($0) }
    }

    static func isUnconditionallyApplicableScreenMediaQuery(_ query: Substring) -> Bool {
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

    static func regexMatchCount(in text: String, pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }
}
