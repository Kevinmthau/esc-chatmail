import Foundation

enum TextProcessing {
    /// Pre-compiled regex for list item detection
    /// Matches: 1. 10. 100. a) A. - * • · (a) (1)
    private static let listItemPattern: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "^(\\d{1,3}[.)]|[a-zA-Z][.)]|[-*•·]|\\([a-zA-Z0-9]{1,3}\\))\\s",
            options: []
        )
    }()

    private static let signatureDelimiterPattern = SignaturePatterns.delimiterLine

    /// Canonical CRLF/CR → LF normalization for the text-processing pipeline.
    static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

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
        if containsUnclosedOpeningTag(html) {
            return recoverPlainTextFromMalformedHTML(from: html)
        }

        guard containsLikelyHTMLMarkup(html) else {
            return normalizePlainTextInput(html)
        }

        if let document = EmailDocument.tryParse(html) {
            let text = document.plainText(preserveParagraphs: true, divsAsLineBreaks: true)
            if !text.isEmpty {
                return text
            }
            // SwiftSoup can parse malformed fragments into an empty body. Let
            // the existing malformed-HTML recovery recover visible text after it.
        }

        return recoverPlainTextFromMalformedHTML(from: html)
    }

    private struct ReplacementRule {
        let regex: NSRegularExpression
        let template: String
    }

    /// Compiles an ordered rule list once. A rule that fails to compile is
    /// dropped, which leaves the text unchanged for that step, as the per-call
    /// `replacingOccurrences` did with an invalid pattern.
    private static func compiledRules(
        _ rules: [(pattern: String, template: String, options: NSRegularExpression.Options)]
    ) -> [ReplacementRule] {
        rules.compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern, options: rule.options))
                .map { ReplacementRule(regex: $0, template: rule.template) }
        }
    }

    /// Applies `rules` in order over the full range, the same replacement
    /// `replacingOccurrences(of:with:options: .regularExpression)` performed.
    private static func applying(_ rules: [ReplacementRule], to text: String) -> String {
        rules.reduce(text) { result, rule in
            rule.regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
    }

    /// The three whitespace-collapse steps normalizePlainTextInput and
    /// recoverPlainTextFromMalformedHTML both end with, in that order. The
    /// per-call replacements passed only `.regularExpression`, so no options.
    private static let whitespaceNormalizationRules: [ReplacementRule] = compiledRules([
        ("[ \\t]+", " ", []),
        ("\\n[ \\t]*\\n", "\n\n", []),
        ("(\\s*\\n\\s*){2,}", "\n\n", [])
    ])

    /// recoverPlainTextFromMalformedHTML's structural steps, in its order, up to
    /// the first non-regex replacement. The <head> and comment patterns keep
    /// the `.caseInsensitive` their per-call replacements passed; the rest
    /// passed only `.regularExpression`.
    private static let malformedHTMLStructureRules: [ReplacementRule] = compiledRules([
        // Avoid leaking <head> metadata (title tags, MSO conditionals) into bubble text.
        // Also strip HTML comments entirely; conditional comments often contain Outlook-only XML
        // that can show up as garbage like "96" in extracted plain text.
        ("<head\\b[^>]*>[\\s\\S]*?</head>", "", [.caseInsensitive]),
        ("<!--[\\s\\S]*?-->", "", [.caseInsensitive]),
        // Remove script and style tags and their content
        ("<script[^>]*>[\\s\\S]*?</script>", "", []),
        ("<style[^>]*>[\\s\\S]*?</style>", "", []),
        // Convert consecutive <br> tags to paragraph breaks, single <br> to space (soft wrap)
        // First: <br><br> or <br>\s*<br> → paragraph break
        ("<br[^>]*>\\s*<br[^>]*>", "\n\n", []),
        // Then: remaining single <br> → newline (let unwrapEmailLineBreaks decide whether to join)
        ("<br[^>]*>", "\n", []),
        // Paragraphs and headings get double newlines (actual content breaks)
        ("</p>", "\n\n", []),
        ("</h[1-6]>", "\n\n", [])
    ])

    /// Table cells get a space so text doesn't run together (`.caseInsensitive`, as before).
    private static let tableCellCloseRule: [ReplacementRule] = compiledRules([
        ("</t[dh]>", " ", [.caseInsensitive])
    ])

    /// Tag removal: every remaining tag, then truncated opening tags (e.g. a
    /// snippet cut in the middle of `<div style="...`).
    private static let malformedHTMLTagStripRules: [ReplacementRule] = compiledRules([
        ("<[^>]+>", "", []),
        ("<[a-zA-Z][^>\\n]*(?=\\n|$)", "", [])
    ])

    /// `^(https?://|www\.)` with `.caseInsensitive`, the option the per-line
    /// `range(of:options:)` in unwrapEmailLineBreaks passed; it tested this on
    /// every non-empty line. A nil regex reads as "not a URL line", which is
    /// what a nil `range(of:)` result meant there.
    private static let urlLeadingLineRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(https?://|www\.)"#, options: [.caseInsensitive])
    }()

    private static func startsWithURL(_ line: String) -> Bool {
        guard let regex = urlLeadingLineRegex else { return false }
        return regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func normalizePlainTextInput(_ text: String) -> String {
        var normalized = decodeHTMLEntities(text)

        normalized = normalized.unicodeScalars.filter { scalar in
            scalar.value != 0x200B && scalar.value != 0x200C && scalar.value != 0x200D
        }.map { String($0) }.joined()

        normalized = applying(whitespaceNormalizationRules, to: normalized)
        normalized = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func recoverPlainTextFromMalformedHTML(from html: String) -> String {
        // Structural cleanup (head, comments, script/style, <br>, paragraph and
        // heading closes); the rule list carries the step-by-step comments.
        var text = applying(malformedHTMLStructureRules, to: html)

        // Div closures create single newlines - let unwrapEmailLineBreaks decide whether to join
        // Gmail mobile wraps each line in <div>, so using \n allows smart join logic to work
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive, range: nil)

        // List items should each appear on their own line
        text = text.replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive, range: nil)

        // Tables: preserve row boundaries and add spacing between cells so text doesn't run together.
        // This is important for quote removal: Outlook/Apple "From/Sent/To/Subject" quote headers are often rendered in tables.
        text = applying(tableCellCloseRule, to: text)
        text = text.replacingOccurrences(of: "</tr>", with: "\n", options: .caseInsensitive, range: nil)
        text = text.replacingOccurrences(of: "</table>", with: "\n\n", options: .caseInsensitive, range: nil)

        // Remove all HTML tags, then truncated opening tags (e.g., snippet cut in middle of `<div style="...`).
        text = applying(malformedHTMLTagStripRules, to: text)

        // Decode HTML entities in a single pass using the pre-built lookup table
        text = decodeHTMLEntities(text)

        // Strip zero-width Unicode characters in one pass
        text = text.unicodeScalars.filter { scalar in
            scalar.value != 0x200B && scalar.value != 0x200C && scalar.value != 0x200D
        }.map { String($0) }.joined()

        // Clean up whitespace: collapse runs of spaces/tabs, whitespace-only
        // lines to a single newline, then any newline sequence to at most two.
        text = applying(whitespaceNormalizationRules, to: text)

        // Trim whitespace from each line to clean up artifacts like " \n" from decoded &nbsp;
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    private static let knownHTMLTagNames: Set<String> = [
        "a", "abbr", "address", "area", "article", "aside", "audio",
        "b", "bdi", "bdo", "blockquote", "body", "br",
        "caption", "center", "cite", "code", "col", "colgroup",
        "data", "datalist", "dd", "del", "details", "dfn", "dialog", "dir", "div", "dl", "dt",
        "em", "figcaption", "figure", "font", "footer", "form",
        "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html",
        "i", "iframe", "img", "input", "ins", "kbd", "li", "link", "main", "map", "mark", "menu", "meta", "meter",
        "nav", "noscript", "object", "ol", "p", "picture", "pre", "progress",
        "q", "rp", "rt", "ruby", "s", "samp", "script", "section", "small", "source", "span", "strike",
        "strong", "style", "sub", "summary", "sup", "svg",
        "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "time", "title", "tr", "track",
        "u", "ul", "var", "video", "wbr"
    ]

    private static func containsLikelyHTMLMarkup(_ html: String) -> Bool {
        var index = html.startIndex

        while let tagStart = html[index...].firstIndex(of: "<") {
            let nextIndex = html.index(after: tagStart)
            guard nextIndex < html.endIndex else { return false }

            let firstCharacter = html[nextIndex]
            if firstCharacter.isLetter,
               let tagEnd = tagEndIndex(in: html, from: nextIndex) {
                let tagNameStart = nextIndex
                var tagNameEnd = tagNameStart
                while tagNameEnd < html.endIndex, isTagNameCharacter(html[tagNameEnd]) {
                    tagNameEnd = html.index(after: tagNameEnd)
                }

                let tagName = String(html[tagNameStart..<tagNameEnd]).lowercased()
                if knownHTMLTagNames.contains(tagName) ||
                    tagHasAttributes(in: html, nameEnd: tagNameEnd, tagEnd: tagEnd) ||
                    hasExplicitCloseTag(named: tagName, in: html, after: html.index(after: tagEnd)) {
                    return true
                }
            } else if firstCharacter == "!",
                      html[nextIndex...].lowercased().hasPrefix("!doctype"),
                      tagEndIndex(in: html, from: nextIndex) != nil {
                return true
            }
            if firstCharacter == "!",
               html[nextIndex...].hasPrefix("!--"),
               html[nextIndex...].range(of: "-->") != nil {
                return true
            }

            if firstCharacter == "/" {
                let nameStart = html.index(after: nextIndex)
                var nameEnd = nameStart
                while nameEnd < html.endIndex, isTagNameCharacter(html[nameEnd]) {
                    nameEnd = html.index(after: nameEnd)
                }

                let tagName = String(html[nameStart..<nameEnd]).lowercased()
                if nameStart < html.endIndex,
                   html[nameStart].isLetter,
                   knownHTMLTagNames.contains(tagName),
                   tagEndIndex(in: html, from: nameEnd) != nil {
                    return true
                }
            }

            index = nextIndex
        }

        return false
    }

    /// Whether some `<` and a letter has no `tagEndIndex` after it.
    ///
    /// One pass from the end, not a `tagEndIndex` walk from every `<`: that
    /// was quadratic, and a sender's `<a` repeated 20,000 times then `>`
    /// (40 KB) took 4 s ahead of every text extraction. Walking back, it keeps
    /// whether `tagEndIndex` would find its `>` from the next character with
    /// no quote open, inside `"`, or inside `'`, which is all that walk
    /// depends on, so the answer is the same
    /// (`TextProcessingUnclosedTagTests` compares the two).
    static func containsUnclosedOpeningTag(_ html: String) -> Bool {
        // The state is for the character after the one being read; walked in
        // place, as an `Array` of `Character`s cost 16 bytes a character.
        var reachesEndOutsideQuotes = false
        var reachesEndInDoubleQuote = false
        var reachesEndInSingleQuote = false
        var following: Character?
        var index = html.endIndex
        while index > html.startIndex {
            index = html.index(before: index)
            let character = html[index]
            if character == "<", following?.isLetter == true, !reachesEndOutsideQuotes {
                return true
            }
            let outsideQuotes: Bool
            switch character {
            case ">": outsideQuotes = true
            case "\"": outsideQuotes = reachesEndInDoubleQuote
            case "'": outsideQuotes = reachesEndInSingleQuote
            default: outsideQuotes = reachesEndOutsideQuotes
            }
            if character == "\"" {
                reachesEndInDoubleQuote = reachesEndOutsideQuotes
            }
            if character == "'" {
                reachesEndInSingleQuote = reachesEndOutsideQuotes
            }
            reachesEndOutsideQuotes = outsideQuotes
            following = character
        }
        return false
    }

    private static func tagEndIndex(in html: String, from startIndex: String.Index) -> String.Index? {
        var index = startIndex
        var quote: Character?

        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }

            index = html.index(after: index)
        }

        return nil
    }

    private static func tagHasAttributes(in html: String, nameEnd: String.Index, tagEnd: String.Index) -> Bool {
        var index = nameEnd
        var hasAttributeSeparator = false

        while index < tagEnd {
            if html[index].isWhitespace {
                hasAttributeSeparator = true
                index = html.index(after: index)
                continue
            }

            guard hasAttributeSeparator, html[index] != "/" else {
                return false
            }

            let attributeNameStart = index
            while index < tagEnd, isAttributeNameCharacter(html[index]) {
                index = html.index(after: index)
            }

            guard attributeNameStart < index else {
                return false
            }

            while index < tagEnd, html[index].isWhitespace {
                index = html.index(after: index)
            }

            if index < tagEnd, html[index] == "=" {
                return true
            }

            hasAttributeSeparator = false
        }

        return false
    }

    private static func hasExplicitCloseTag(
        named tagName: String,
        in html: String,
        after startIndex: String.Index
    ) -> Bool {
        var index = startIndex

        while let tagStart = html[index...].firstIndex(of: "<") {
            let afterOpen = html.index(after: tagStart)
            guard afterOpen < html.endIndex else { return false }

            guard html[afterOpen] == "/" else {
                index = afterOpen
                continue
            }

            let nameStart = html.index(after: afterOpen)
            var nameEnd = nameStart
            while nameEnd < html.endIndex, isTagNameCharacter(html[nameEnd]) {
                nameEnd = html.index(after: nameEnd)
            }

            guard String(html[nameStart..<nameEnd]).caseInsensitiveCompare(tagName) == .orderedSame,
                  let tagEnd = tagEndIndex(in: html, from: nameEnd) else {
                index = nameEnd
                continue
            }

            var closeRemainder = nameEnd
            while closeRemainder < tagEnd, html[closeRemainder].isWhitespace {
                closeRemainder = html.index(after: closeRemainder)
            }

            if closeRemainder == tagEnd {
                return true
            }

            index = html.index(after: tagEnd)
        }

        return false
    }

    private static func isTagNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == ":" || character == "_"
    }

    private static func isAttributeNameCharacter(_ character: Character) -> Bool {
        !character.isWhitespace &&
            character != "/" &&
            character != ">" &&
            character != "=" &&
            character != "\"" &&
            character != "'" &&
            character != "<"
    }

    static func stripQuotedText(from text: String) -> String {
        // Delegate to PlainTextQuoteRemover for unified quote and signature removal
        PlainTextQuoteRemover.removeQuotes(from: text) ?? text
    }

    static func stripSignatures(from text: String) -> String {
        PlainTextSignatureRemover.removeSignature(from: text)
    }

    /// Sign-offs that get a line break before them when they appear inline at the
    /// end of text. Derived from the shared vocabulary so unwrap, formatting and the
    /// signature passes agree on what a closing is. Longest first so a multi-word
    /// closing wins over its shorter suffix; `Set` iteration order is not stable, so
    /// the order is fixed here.
    private static let signOffWords: [String] = SignaturePatterns.signOffPhrases.sorted {
        $0.count == $1.count ? $0 < $1 : $0.count > $1.count
    }

    private struct SignOffLineBreakPattern {
        let regex: NSRegularExpression
        let patternIndex: Int
    }

    /// Three shapes per closing, compiled once. This runs on every bubble derivation
    /// and on the launch-time preview repair, so compiling 130-odd expressions per call
    /// was real cost. Grouped per closing to keep the one-match-per-closing loop below.
    private static let signOffLineBreakPatterns: [[SignOffLineBreakPattern]] = signOffWords.map { signOff in
        let escapedSignOff = NSRegularExpression.escapedPattern(for: signOff)
        let shapes = [
            "([.!?])\\s+(\(escapedSignOff))([!.])?,?\\s*$",  // "help. Regards" or "help. Thanks!" at end - group 3 captures trailing punct
            "([.!?])\\s+(\(escapedSignOff)),\\s+([A-Z][a-z]+)\\s*$",  // "help. Regards, Kevin" at end
            "([.!?])\\s+(\(escapedSignOff)),\\s+([A-Z][a-z]+)\\s+([A-Z][a-z]+)\\s*$",  // "help. Regards, Kevin Thau" at end
        ]
        return shapes.enumerated().compactMap { patternIndex, pattern in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
                .map { SignOffLineBreakPattern(regex: $0, patternIndex: patternIndex) }
        }
    }

    /// Adds line breaks before sign-offs when they appear inline at the end of text
    /// Handles cases like "...for your help. Regards, Kevin" → "...for your help.\n\nRegards,\n\nKevin"
    static func formatSignOffLineBreaks(in text: String) -> String {
        var result = text

        // Pattern: sentence ending (. ! ?) followed by space and a sign-off word
        for patterns in signOffLineBreakPatterns {
            for entry in patterns {
                let regex = entry.regex
                let patternIndex = entry.patternIndex
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

        return result
    }

    /// Unwraps artificial email line breaks (72-80 char wrapping) while preserving paragraph breaks
    /// Emails often contain hard line breaks at fixed widths for legacy compatibility.
    /// This function joins lines that were artificially wrapped while keeping intentional paragraph breaks.
    ///
    /// Linear in the text's length. It used to re-split, trim and lowercase the
    /// whole growing paragraph for every line it joined, which made one run of
    /// joinable lines (a log, a file listing, CSV) quadratic: minutes for a
    /// megabyte, inside a sync batch that cannot be cancelled. `UnwrapParagraph`
    /// now keeps what those checks read as the lines are added, and the output
    /// is byte-identical (`TextProcessingUnwrapLinearityTests` compares it with
    /// a copy of the old function).
    static func unwrapEmailLineBreaks(from text: String) -> String {
        var normalizedText = normalizeLineEndings(text)

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
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }

        var result: [String] = []
        var paragraph = UnwrapParagraph()
        // The first non-empty line at or after the blank line being read. Every
        // blank line of one run looks ahead to the same line, so the run is
        // walked once instead of once per blank line.
        var nextNonEmptyLookahead = -1
        var i = 0

        while i < lines.count {
            let trimmedLine = trimmedLines[i]
            i += 1

            // Skip empty lines but check if we should join across them
            if trimmedLine.isEmpty {
                if paragraph.isEmpty {
                    continue
                }

                // Look ahead to find the next non-empty line
                if nextNonEmptyLookahead < i {
                    nextNonEmptyLookahead = i
                    while nextNonEmptyLookahead < lines.count &&
                          trimmedLines[nextNonEmptyLookahead].isEmpty {
                        nextNonEmptyLookahead += 1
                    }
                }
                let nextNonEmptyIndex = nextNonEmptyLookahead

                // Check if we should join across the blank line(s)
                if nextNonEmptyIndex < lines.count {
                    let nextLine = trimmedLines[nextNonEmptyIndex]
                    let currentIsSignatureDelimiter = paragraph.isSignatureDelimiterLine
                    let nextIsSignatureDelimiter = isSignatureDelimiterLine(nextLine)
                    let lastChar = paragraph.text.last
                    let firstChar = nextLine.first

                    let endsWithPunctuation = lastChar.map { ".!?".contains($0) } ?? false
                    // Join unless next line starts with uppercase (new sentence)
                    let startsWithUppercase = firstChar?.isUppercase ?? false

                    if !endsWithPunctuation &&
                        !startsWithUppercase &&
                        !startsWithURL(nextLine) &&
                        !currentIsSignatureDelimiter &&
                        !nextIsSignatureDelimiter {
                        // This is a soft wrap across blank lines - skip the blanks and continue joining
                        continue
                    }
                }

                // Real paragraph break - flush current paragraph
                result.append(paragraph.text)
                result.append("") // Add paragraph separator
                paragraph = UnwrapParagraph()
                continue
            }

            if paragraph.isEmpty {
                paragraph.start(with: trimmedLine)
            } else {
                // Keep a name on its own line after a standalone sign-off. The
                // name check reads only the new line, so it goes first.
                if looksLikeNameLine(trimmedLine), paragraph.lastLineIsStandaloneSignOff {
                    paragraph.appendOnNewLine(trimmedLine)
                    continue
                }

                // Check if this looks like a continuation (soft wrap) or new paragraph
                let lastChar = paragraph.text.last
                let firstChar = trimmedLine.first

                let endsWithPunctuation = lastChar.map { ".!?".contains($0) } ?? false
                // Join unless next line starts with uppercase (new sentence)
                let startsWithUppercase = firstChar?.isUppercase ?? false

                // Don't join if current line ends with colon (often precedes lists)
                let endsWithColon = lastChar == ":"

                // Don't join if next line looks like a list item
                // Handles: 1. 10. 100. a) A. - * • · (a) (1)
                let isListItem = TextProcessing.isListItem(trimmedLine)
                let currentIsSignatureDelimiter = paragraph.isSignatureDelimiterLine
                let nextIsSignatureDelimiter = isSignatureDelimiterLine(trimmedLine)

                if !endsWithPunctuation &&
                    !endsWithColon &&
                    !startsWithUppercase &&
                    !startsWithURL(trimmedLine) &&
                    !isListItem &&
                    !currentIsSignatureDelimiter &&
                    !nextIsSignatureDelimiter {
                    // Join with space (unwrap soft line break)
                    paragraph.appendJoined(trimmedLine)
                } else {
                    // New paragraph
                    result.append(paragraph.text)
                    paragraph = UnwrapParagraph()
                    paragraph.start(with: trimmedLine)
                }
            }
        }

        if !paragraph.isEmpty {
            result.append(paragraph.text)
        }

        // Filter out empty strings and join with double newlines for paragraph breaks
        let paragraphs = result.filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The paragraph `unwrapEmailLineBreaks` is building, with what its join
    /// checks read about it kept up to date as lines are added, so no check
    /// re-reads the whole paragraph. Lines arrive trimmed and non-empty, are
    /// joined by " " or "\n", and contain no "\n" of their own (the text was
    /// split on it).
    private struct UnwrapParagraph {
        private(set) var text = ""
        /// Lines holding something other than whitespace and newlines.
        private var contentLineCount = 0
        private var firstContentLine: String?
        private var lastLine = UnwrapLastLine()

        var isEmpty: Bool { text.isEmpty }

        mutating func start(with line: String) {
            text = line
            noteLine(line)
            lastLine = UnwrapLastLine(firstSegment: line)
        }

        mutating func appendOnNewLine(_ line: String) {
            text += "\n" + line
            noteLine(line)
            lastLine = UnwrapLastLine(firstSegment: line)
        }

        mutating func appendJoined(_ line: String) {
            text += " " + line
            noteLine(line)
            lastLine.append(" " + line)
        }

        /// `isSignatureDelimiterLine(text)`. That trims the paragraph before
        /// matching, so it sees one content line alone and is false for two:
        /// the separator between them is whitespace inside the match, which
        /// none of the delimiter shapes allows.
        var isSignatureDelimiterLine: Bool {
            guard contentLineCount == 1, let firstContentLine else { return false }
            return TextProcessing.isSignatureDelimiterLine(firstContentLine)
        }

        /// `isStandaloneSignOffLine` of the paragraph's last line trimmed of
        /// whitespace and newlines: whether a name on the next line keeps its
        /// own line.
        var lastLineIsStandaloneSignOff: Bool {
            mutating get { lastLine.isStandaloneSignOff }
        }

        private mutating func noteLine(_ line: String) {
            guard line.unicodeScalars.contains(where: { !Self.whitespaceAndNewlines.contains($0) }) else { return }
            contentLineCount += 1
            if firstContentLine == nil {
                firstContentLine = line
            }
        }

        private static let whitespaceAndNewlines = CharacterSet.whitespacesAndNewlines
    }

    /// The paragraph's last line (the text after its last "\n"), with enough
    /// kept about its ends to answer `isStandaloneSignOffLine` without
    /// reading the whole line every time a segment is added.
    ///
    /// That check lowercases the line, trims whitespace and newlines from
    /// both ends, then punctuation, and looks the rest up among the sign-off
    /// phrases. Lowercasing maps each scalar to one or more scalars of the
    /// same kind (a letter to letters, never to whitespace or punctuation), so
    /// what is left has at least as many scalars as the same trimming leaves
    /// of the line itself. The phrases are ASCII, and a string equal to one
    /// (Swift compares canonically) has no more scalars than it. So a line
    /// whose trimmed middle is longer than the longest phrase is no sign-off,
    /// and only a short middle runs the real check. The middle grows by at
    /// least one scalar for each segment holding more than whitespace, so a
    /// line runs it at most `longestPhraseScalarCount + 1` times. Whitespace
    /// added at the end is trimmed away and cannot change the answer.
    private struct UnwrapLastLine {
        private enum LeadingTrim {
            case whitespace
            case punctuation
            case done
        }

        private var line = ""
        private var scalarCount = 0
        private var leadingTrim = LeadingTrim.whitespace
        private var leadingTrimmedScalarCount = 0
        private var trailingWhitespaceScalarCount = 0
        private var trailingPunctuationScalarCount = 0
        private var cachedAnswer: Bool?

        private static let whitespaceAndNewlines = CharacterSet.whitespacesAndNewlines
        private static let punctuation = CharacterSet.punctuationCharacters

        init() {}

        init(firstSegment: String) {
            append(firstSegment)
        }

        mutating func append(_ segment: String) {
            let scalars = Array(segment.unicodeScalars)
            line += segment
            scalarCount += scalars.count

            var index = 0
            while leadingTrim != .done, index < scalars.count {
                let scalar = scalars[index]
                switch leadingTrim {
                case .whitespace:
                    if Self.whitespaceAndNewlines.contains(scalar) {
                        leadingTrimmedScalarCount += 1
                    } else if Self.punctuation.contains(scalar) {
                        leadingTrimmedScalarCount += 1
                        leadingTrim = .punctuation
                    } else {
                        leadingTrim = .done
                    }
                case .punctuation:
                    if Self.punctuation.contains(scalar) {
                        leadingTrimmedScalarCount += 1
                    } else {
                        leadingTrim = .done
                    }
                case .done:
                    break
                }
                index += 1
            }

            var end = scalars.count
            while end > 0, Self.whitespaceAndNewlines.contains(scalars[end - 1]) {
                end -= 1
            }
            if end == 0 {
                // Whitespace only: trimmed off the end again, answer unchanged.
                trailingWhitespaceScalarCount += scalars.count
                return
            }
            trailingWhitespaceScalarCount = scalars.count - end
            var punctuationStart = end
            while punctuationStart > 0, Self.punctuation.contains(scalars[punctuationStart - 1]) {
                punctuationStart -= 1
            }
            trailingPunctuationScalarCount = end - punctuationStart
            cachedAnswer = nil
        }

        var isStandaloneSignOff: Bool {
            mutating get {
                // Nothing but leading whitespace then punctuation: trims to "".
                guard leadingTrim == .done else { return false }
                let middleScalarCount = scalarCount
                    - leadingTrimmedScalarCount
                    - trailingWhitespaceScalarCount
                    - trailingPunctuationScalarCount
                guard middleScalarCount <= TextProcessing.longestSignOffScalarCount else { return false }
                if let cachedAnswer {
                    return cachedAnswer
                }
                let answer = TextProcessing.isStandaloneSignOffLine(
                    line.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                cachedAnswer = answer
                return answer
            }
        }
    }

    // MARK: - HTML Entity Decoding

    /// Lookup table for HTML entities → replacement strings.
    /// Using a single-pass scanner instead of 30+ sequential replacingOccurrences calls.
    private static let htmlEntityMap: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "zwnj": "", "zwj": "",
        "ldquo": "\"", "rdquo": "\"", "lsquo": "'", "rsquo": "'",
        "ndash": "–", "mdash": "—", "hellip": "…",
    ]

    /// Lookup for numeric character references (&#NNN; and &#xHH;)
    private static let numericEntityMap: [String: String] = [
        "160": " ", "39": "'", "34": "\"",
        "8204": "", "8205": "",
        "8220": "\"", "8221": "\"", "8216": "'", "8217": "'",
        "8211": "–", "8212": "—", "8230": "…",
    ]

    private static let hexEntityMap: [String: String] = [
        "a0": " ", "200c": "", "200d": "",
    ]

    /// Decodes HTML entities in a single pass using a scanner approach.
    private static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "&" {
                // Look for closing semicolon within a reasonable range
                let searchEnd = text.index(index, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
                if let semicolonIndex = text[index...].prefix(through: searchEnd > index ? text.index(before: searchEnd) : index).firstIndex(of: ";"),
                   semicolonIndex > text.index(after: index) {
                    let entityStart = text.index(after: index)
                    let entity = String(text[entityStart..<semicolonIndex])

                    var replacement: String?
                    if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                        let hex = String(entity.dropFirst(2)).lowercased()
                        replacement = hexEntityMap[hex]
                    } else if entity.hasPrefix("#") {
                        let num = String(entity.dropFirst())
                        replacement = numericEntityMap[num]
                    } else {
                        replacement = htmlEntityMap[entity.lowercased()]
                    }

                    if let replacement = replacement {
                        result += replacement
                        index = text.index(after: semicolonIndex)
                        continue
                    }
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }

        return result
    }

    /// The most scalars any sign-off phrase has (`UnwrapLastLine`).
    fileprivate static let longestSignOffScalarCount = signOffWords.map(\.unicodeScalars.count).max() ?? 0

    fileprivate static func isStandaloneSignOffLine(_ line: String) -> Bool {
        let normalized = line
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)

        return signOffWords.contains(normalized)
    }

    private static func looksLikeNameLine(_ line: String) -> Bool {
        SignatureSignOffPolicy.looksLikeNameLine(line)
    }

    fileprivate static func isSignatureDelimiterLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let pattern = signatureDelimiterPattern else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return pattern.firstMatch(in: trimmed, options: [], range: range) != nil
    }
}
