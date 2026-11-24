import Foundation

/// Linear forms of the steps of `TextProcessing.extractPlainText` (and of the
/// snippet's preparation, `MessageProcessor.prepareHTMLForSnippet`) that read
/// a sender's markup more than once.
///
/// Each gives the same answer as the code it replaced, which was quadratic on
/// markup a sender can write: 40 KB of unclosed `<!--` held a message's text
/// extraction for 4.5 s and its whole ingest for 15 s, unclosed `<script>` or
/// `<style>` 2 s at 60–70 KB, and `<foo>` repeated with no `</foo>` 5.6 s at
/// 46 KB (iOS 27.0 simulator, Debug). All of it runs ahead of the extracted
/// text's cap (`ChatBubbleTextProcessor.cappedExtractedText`) and on the
/// uncapped `bodyText` and `cleanedSnippet`. `HTMLMarkupScanTests` compares
/// each with the code it replaced over generated markup.
enum HTMLMarkupScan {

    // MARK: - Does this read as markup?

    /// `TextProcessing.containsLikelyHTMLMarkup`: whether some `<` opens a known
    /// tag, a tag with an attribute, or a tag with an explicit close tag after
    /// it; or a doctype or a closed comment; or closes a known tag.
    ///
    /// The walk it replaced read, at each `<`, to the tag's `>` and, for an
    /// unknown tag, to the end of the text for its close tag, and lowercased
    /// the rest of the text at each `<!`. Here every `<`'s `>` comes from one
    /// pass from the end, and the close tags are indexed once by name.
    static func containsLikelyHTMLMarkup(_ html: String) -> Bool {
        let scan = OpeningScan(html)
        var closeTags: CloseTagIndex?
        var commentCloseStart: String.Index??

        for ordinal in scan.openings.indices {
            let nextIndex = html.index(after: scan.openings[ordinal])
            guard nextIndex < html.endIndex else { return false }
            let tagEnd = scan.tagEnds[ordinal]

            let firstCharacter = html[nextIndex]
            if firstCharacter.isLetter, let tagEnd {
                var tagNameEnd = nextIndex
                while tagNameEnd < html.endIndex, TextProcessing.isTagNameCharacter(html[tagNameEnd]) {
                    tagNameEnd = html.index(after: tagNameEnd)
                }
                let tagName = String(html[nextIndex..<tagNameEnd]).lowercased()
                if TextProcessing.knownHTMLTagNames.contains(tagName) ||
                    TextProcessing.tagHasAttributes(in: html, nameEnd: tagNameEnd, tagEnd: tagEnd) {
                    return true
                }
                if closeTags == nil {
                    closeTags = CloseTagIndex(html: html, scan: scan)
                }
                if closeTags!.hasExplicitCloseTag(named: tagName, after: html.index(after: tagEnd)) {
                    return true
                }
            } else if firstCharacter == "!",
                      // The first eight characters decide it; sixteen leave
                      // room for any lowercasing that changes a length.
                      String(html[nextIndex...].prefix(16)).lowercased().hasPrefix("!doctype"),
                      tagEnd != nil {
                return true
            }
            if firstCharacter == "!", html[nextIndex...].hasPrefix("!--") {
                if commentCloseStart == nil {
                    commentCloseStart = .some(html.range(of: "-->", options: .backwards)?.lowerBound)
                }
                if let lastClose = commentCloseStart!, lastClose >= nextIndex {
                    return true
                }
            }

            if firstCharacter == "/" {
                let nameStart = html.index(after: nextIndex)
                var nameEnd = nameStart
                while nameEnd < html.endIndex, TextProcessing.isTagNameCharacter(html[nameEnd]) {
                    nameEnd = html.index(after: nameEnd)
                }
                // From `nameEnd` the tag's `>` is the opening's: the slash and
                // the name hold no quote and no `>`.
                if nameStart < html.endIndex,
                   html[nameStart].isLetter,
                   TextProcessing.knownHTMLTagNames.contains(String(html[nameStart..<nameEnd]).lowercased()),
                   tagEnd != nil {
                    return true
                }
            }
        }
        return false
    }

    /// Every `<`, and its tag end: where the walk from the character after it
    /// lands on the first `>` outside quotes, a quote being opened by `"` or
    /// `'` and closed by the same character.
    private struct OpeningScan {
        let openings: [String.Index]
        let tagEnds: [String.Index?]

        init(_ html: String) {
            var openings: [String.Index] = []
            var searchFrom = html.startIndex
            while let opening = html[searchFrom...].firstIndex(of: "<") {
                openings.append(opening)
                searchFrom = html.index(after: opening)
            }

            // Walked from the end, each state is where the walk from the
            // following character lands: with no quote open, in `"`, in `'`.
            var tagEnds = [String.Index?](repeating: nil, count: openings.count)
            var landsOutsideQuotes: String.Index?
            var landsInDoubleQuote: String.Index?
            var landsInSingleQuote: String.Index?
            var ordinal = openings.count - 1
            var index = html.endIndex
            while index > html.startIndex, ordinal >= 0 {
                index = html.index(before: index)
                if openings[ordinal] == index {
                    tagEnds[ordinal] = landsOutsideQuotes
                    ordinal -= 1
                }
                let outside = landsOutsideQuotes
                switch html[index] {
                case ">":
                    landsOutsideQuotes = index
                case "\"":
                    landsOutsideQuotes = landsInDoubleQuote
                    landsInDoubleQuote = outside
                case "'":
                    landsOutsideQuotes = landsInSingleQuote
                    landsInSingleQuote = outside
                default:
                    break
                }
            }
            self.openings = openings
            self.tagEnds = tagEnds
        }
    }

    /// Whether an unknown tag has an explicit close tag after it, for every
    /// name at once. The walk this replaced
    /// went from `<` to `<` looking for `</name` with only whitespace before
    /// its `>`; a `</name` with anything else there sent it on past that `>`,
    /// past any `</name>` inside, so the answer follows the same jumps here.
    private final class CloseTagIndex {
        private struct CloseTag {
            let opening: String.Index
            let name: String
            let tagEnd: String.Index?
            let isBare: Bool
        }

        private let closeTags: [CloseTag]
        /// Close tags by case-folded name: every name that compares equal
        /// ignoring case to another folds to the same key, and each candidate
        /// is compared exactly before it counts.
        private let byFoldedName: [String: [Int]]
        private var answersByName: [String: (openings: [String.Index], found: [Bool])] = [:]

        init(html: String, scan: OpeningScan) {
            var closeTags: [CloseTag] = []
            var byFoldedName: [String: [Int]] = [:]
            for (opening, tagEnd) in zip(scan.openings, scan.tagEnds) {
                let afterOpen = html.index(after: opening)
                guard afterOpen < html.endIndex, html[afterOpen] == "/" else { continue }
                let nameStart = html.index(after: afterOpen)
                var nameEnd = nameStart
                while nameEnd < html.endIndex, TextProcessing.isTagNameCharacter(html[nameEnd]) {
                    nameEnd = html.index(after: nameEnd)
                }
                // An empty name equals no tag's name.
                guard nameStart < nameEnd else { continue }
                var isBare = false
                if let tagEnd {
                    var remainder = nameEnd
                    while remainder < tagEnd, html[remainder].isWhitespace {
                        remainder = html.index(after: remainder)
                    }
                    isBare = remainder == tagEnd
                }
                let name = String(html[nameStart..<nameEnd])
                byFoldedName[Self.key(name), default: []].append(closeTags.count)
                closeTags.append(CloseTag(opening: opening, name: name, tagEnd: tagEnd, isBare: isBare))
            }
            self.closeTags = closeTags
            self.byFoldedName = byFoldedName
        }

        private static func key(_ name: String) -> String {
            name.folding(options: .caseInsensitive, locale: nil)
        }

        func hasExplicitCloseTag(named tagName: String, after startIndex: String.Index) -> Bool {
            let answers = answers(for: tagName)
            // The first of this name's close tags at or after `startIndex`.
            var low = 0
            var high = answers.openings.count
            while low < high {
                let middle = (low + high) / 2
                if answers.openings[middle] < startIndex {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low < answers.found.count && answers.found[low]
        }

        /// For each close tag named `tagName`, whether the walk that reaches it
        /// finds a bare one: there, or where the walk goes on from it.
        private func answers(for tagName: String) -> (openings: [String.Index], found: [Bool]) {
            if let known = answersByName[tagName] {
                return known
            }
            let tags = (byFoldedName[Self.key(tagName)] ?? [])
                .map { closeTags[$0] }
                .filter { $0.name.caseInsensitiveCompare(tagName) == .orderedSame }
            let openings = tags.map(\.opening)
            var found = [Bool](repeating: false, count: tags.count)
            for position in tags.indices.reversed() {
                let tag = tags[position]
                guard let tagEnd = tag.tagEnd else {
                    // The walk goes on from the end of the name.
                    found[position] = position + 1 < tags.count && found[position + 1]
                    continue
                }
                if tag.isBare {
                    found[position] = true
                    continue
                }
                // The walk goes on past the tag's `>`.
                var next = position + 1
                while next < tags.count, tags[next].opening <= tagEnd {
                    next += 1
                }
                found[position] = next < tags.count && found[next]
            }
            let answers = (openings: openings, found: found)
            answersByName[tagName] = answers
            return answers
        }
    }

    // MARK: - Replacements

    /// `<head\b[^>]*>[\s\S]*?</head>` and the like: a tag, its `>`, then
    /// everything up to the first `close` after that `>`. `start` matches the
    /// tag up to its attributes (`<head\b`, `<script`, `<!--`); with
    /// `readsToTagEnd` the block's body starts after the first `>` past it,
    /// otherwise right after it.
    ///
    /// The same as replacing every match of the regex, linearly. The regex
    /// read, at every `start` with no `close` after its `>`, to the end of the
    /// text (and at every `start` with no `>` after it, to the end again), so
    /// 8,000 unclosed `<!--` cost 8,000 reads of the rest of the text. Each
    /// start that matches here is the one the regex matched; one that does
    /// not means no later start can, because a later start's `>` and `close`
    /// can only come later, so the scan ends there.
    static func replacingBlocks(
        in text: String,
        start: NSRegularExpression,
        readsToTagEnd: Bool,
        close: NSRegularExpression,
        with template: String
    ) -> String {
        let nsText = text as NSString
        let length = nsText.length
        var result = ""
        var copiedThrough = 0
        var searchFrom = 0
        while searchFrom < length,
              let opening = start.firstMatch(
                in: text,
                options: [],
                range: NSRange(location: searchFrom, length: length - searchFrom)
              ) {
            var bodyStart = NSMaxRange(opening.range)
            if readsToTagEnd {
                let tagEnd = nsText.range(
                    of: ">",
                    options: .literal,
                    range: NSRange(location: bodyStart, length: length - bodyStart)
                )
                guard tagEnd.location != NSNotFound else { break }
                bodyStart = tagEnd.location + 1
            }
            guard let closing = close.firstMatch(
                in: text,
                options: [],
                range: NSRange(location: bodyStart, length: length - bodyStart)
            ) else {
                break
            }
            result += nsText.substring(with: NSRange(
                location: copiedThrough,
                length: opening.range.location - copiedThrough
            ))
            result += template
            copiedThrough = NSMaxRange(closing.range)
            searchFrom = copiedThrough
        }
        guard copiedThrough > 0 else { return text }
        result += nsText.substring(from: copiedThrough)
        return result
    }

    /// `<br[^>]*>\s*<br[^>]*>` replaced by `template`, linearly. The regex
    /// read, at each `<br` inside a tag that ran to a far `>`, to that `>` and
    /// over the whitespace after it again (`<br<br<br…>`). What follows a
    /// `>` is read once here and kept for every `<br` that reaches it.
    static func replacingBreakPairs(in text: String, with template: String) -> String {
        let nsText = text as NSString
        let length = nsText.length
        var result = ""
        var copiedThrough = 0
        var searchFrom = 0
        // The last `>` found, and from where: any search from between the two
        // finds it again.
        var knownTagEnd: (from: Int, at: Int)?
        // Where the second tag of a pair that starts after `tagEnd` ends.
        var knownPairEnd: (tagEnd: Int, pairEnd: Int?)?

        func tagEnd(from location: Int) -> Int? {
            if let knownTagEnd, location >= knownTagEnd.from, location <= knownTagEnd.at {
                return knownTagEnd.at
            }
            let found = nsText.range(
                of: ">",
                options: .literal,
                range: NSRange(location: location, length: length - location)
            )
            guard found.location != NSNotFound else { return nil }
            knownTagEnd = (from: location, at: found.location)
            return found.location
        }

        func pairEnd(after firstTagEnd: Int) -> Int? {
            if let knownPairEnd, knownPairEnd.tagEnd == firstTagEnd {
                return knownPairEnd.pairEnd
            }
            var answer: Int?
            var cursor = firstTagEnd + 1
            if cursor < length,
               let whitespace = whitespaceRunRegex?.firstMatch(
                in: text,
                options: .anchored,
                range: NSRange(location: cursor, length: length - cursor)
               ) {
                cursor = NSMaxRange(whitespace.range)
            }
            if cursor + 3 <= length,
               nsText.substring(with: NSRange(location: cursor, length: 3)) == "<br" {
                answer = tagEnd(from: cursor + 3)
            }
            knownPairEnd = (tagEnd: firstTagEnd, pairEnd: answer)
            return answer
        }

        while searchFrom < length {
            let opening = nsText.range(
                of: "<br",
                options: .literal,
                range: NSRange(location: searchFrom, length: length - searchFrom)
            )
            guard opening.location != NSNotFound,
                  let firstTagEnd = tagEnd(from: opening.location + 3) else {
                break
            }
            guard let end = pairEnd(after: firstTagEnd) else {
                searchFrom = opening.location + 1
                continue
            }
            result += nsText.substring(with: NSRange(
                location: copiedThrough,
                length: opening.location - copiedThrough
            ))
            result += template
            copiedThrough = end + 1
            searchFrom = copiedThrough
        }
        guard copiedThrough > 0 else { return text }
        result += nsText.substring(from: copiedThrough)
        return result
    }

    /// `regex` (`<br[^>]*>`, `<[^>]+>`: a tag start, then anything up to the
    /// first `>`) replaced over the text up to its last `>`, which is where
    /// every match ends. The text after it holds no `>`, and the regex read
    /// to the end of the text from every tag start there (`<a<a<a…`).
    static func replacingTagsEndingAtTagEnd(
        in text: String,
        regex: NSRegularExpression,
        with template: String
    ) -> String {
        let nsText = text as NSString
        let lastTagEnd = nsText.range(of: ">", options: [.literal, .backwards])
        guard lastTagEnd.location != NSNotFound else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: NSMaxRange(lastTagEnd)),
            withTemplate: template
        )
    }

    private static let whitespaceRunRegex = try? NSRegularExpression(pattern: "\\s*", options: [])

    // MARK: - Hidden elements

    /// `MessageProcessor.prepareHTMLForSnippet`'s hidden-element pattern: an
    /// element whose `style` hides it, through its close tag (`</\1>`).
    static let hiddenElementRegex = try? NSRegularExpression(
        pattern: "<([a-zA-Z0-9]+)\\b[^>]*style\\s*=\\s*['\"][^'\"]*(?:\(hidingDeclarationPattern))[^'\"]*['\"][^>]*>[\\s\\S]*?</\\1>",
        options: [.caseInsensitive]
    )

    private static let hidingDeclarationPattern =
        "display\\s*:\\s*none|visibility\\s*:\\s*hidden|mso-hide\\s*:\\s*all|max-height\\s*:\\s*0|opacity\\s*:\\s*0|font-size\\s*:\\s*0"
    private static let elementStartRegex = try? NSRegularExpression(pattern: "<([a-zA-Z0-9]+)\\b", options: [.caseInsensitive])
    private static let styleWordRegex = try? NSRegularExpression(pattern: "style", options: [.caseInsensitive])
    private static let styleAssignmentRegex = try? NSRegularExpression(pattern: "\\s*=\\s*['\"]", options: [.caseInsensitive])
    private static let hidingDeclarationRegex = try? NSRegularExpression(pattern: hidingDeclarationPattern, options: [.caseInsensitive])
    private static let closeTagRegex = try? NSRegularExpression(pattern: "</([a-zA-Z0-9]+)>", options: [.caseInsensitive])

    /// Every match of `hiddenElementRegex` removed, with the regex's own result
    /// and without its rereading. The regex tried every `<name` and, at each,
    /// read to the tag's `>` and through every `style` before it, and from
    /// each such tag end to the end of the text for a close tag: a sender's
    /// `<div style="a` repeated 8,000 times (101 KB) held a message's snippet
    /// for 35 s.
    ///
    /// Here each `<name`'s match is worked out from two indexes built once.
    /// The regex's tag can end at more than one `>`: a `style` whose value
    /// hides the element ends the tag at the first `>` after the value's
    /// closing quote. The regex tries the last such `style` before the tag's
    /// first `>` first, then each earlier one, and takes the first whose end
    /// has a close tag of the name after it, through the first such close
    /// tag. Those ends never decrease from one `style` to the next (a value
    /// holds no quote, so a later `style`'s value starts at or after an
    /// earlier one's closing quote), so the `style`s with a close tag after
    /// their end come first, and the regex takes the last of them. A name with
    /// a character outside ASCII, which the regex's case folding could equate
    /// with another, is left to the regex, as is every name in a text with
    /// such a close tag.
    static func removingHiddenElements(from text: String) -> String {
        guard let hiddenElementRegex, let elementStartRegex else { return text }
        let nsText = text as NSString
        let length = nsText.length
        let styles = HidingStyles(text)
        let closeTags = CloseTagPositions(text)

        var result = ""
        var copiedThrough = 0
        var searchFrom = 0
        var knownTagEnd: (from: Int, at: Int?)?
        func firstTagEnd(from location: Int) -> Int? {
            if let knownTagEnd, location >= knownTagEnd.from,
               knownTagEnd.at.map({ location <= $0 }) ?? true {
                return knownTagEnd.at
            }
            let found = nsText.range(
                of: ">",
                options: .literal,
                range: NSRange(location: location, length: length - location)
            )
            let at = found.location == NSNotFound ? nil : found.location
            knownTagEnd = (from: location, at: at)
            return at
        }

        while searchFrom < length,
              let start = elementStartRegex.firstMatch(
                in: text,
                options: [],
                range: NSRange(location: searchFrom, length: length - searchFrom)
              ) {
            let nameEnd = NSMaxRange(start.range)
            guard let tagEnd = firstTagEnd(from: nameEnd) else { break }
            let candidates = styles.indices(atOrAfter: nameEnd, before: tagEnd)
            var matchEnd: Int?
            if !candidates.isEmpty {
                let name = nsText.substring(with: start.range(at: 1))
                switch closeTags.closes(forName: name) {
                case .indexed(let closes):
                    if let lastClose = closes.last?.location {
                        let lastWithClose = styles.lastIndex(in: candidates) { $0.elementEnd < lastClose }
                        if let lastWithClose {
                            let elementEnd = styles[lastWithClose].elementEnd
                            matchEnd = closes.first { $0.location > elementEnd }.map(NSMaxRange)
                        }
                    }
                case .leftToTheRegex:
                    matchEnd = hiddenElementRegex.firstMatch(
                        in: text,
                        options: .anchored,
                        range: NSRange(location: start.range.location, length: length - start.range.location)
                    ).map { NSMaxRange($0.range) }
                }
            }
            guard let matchEnd else {
                searchFrom = start.range.location + 1
                continue
            }
            result += nsText.substring(with: NSRange(
                location: copiedThrough,
                length: start.range.location - copiedThrough
            ))
            copiedThrough = matchEnd
            searchFrom = copiedThrough
        }
        guard copiedThrough > 0 else { return text }
        result += nsText.substring(from: copiedThrough)
        return result
    }

    /// Every `style` whose attribute value holds a hiding declaration, in
    /// order, with the `>` its tag would end at.
    private struct HidingStyles {
        struct Style {
            let location: Int
            /// The first `>` after the value's closing quote.
            let elementEnd: Int
        }

        private let styles: [Style]

        init(_ text: String) {
            let nsText = text as NSString
            let length = nsText.length
            let quotes = CharacterSet(charactersIn: "'\"")
            var styles: [Style] = []
            var knownTagEnd: (from: Int, at: Int?)?
            var searchFrom = 0
            while searchFrom < length,
                  let styleRegex = HTMLMarkupScan.styleWordRegex,
                  let assignmentRegex = HTMLMarkupScan.styleAssignmentRegex,
                  let hidingRegex = HTMLMarkupScan.hidingDeclarationRegex,
                  let word = styleRegex.firstMatch(
                    in: text,
                    options: [],
                    range: NSRange(location: searchFrom, length: length - searchFrom)
                  ) {
                searchFrom = word.range.location + 1
                let afterWord = NSMaxRange(word.range)
                guard let assignment = assignmentRegex.firstMatch(
                    in: text,
                    options: .anchored,
                    range: NSRange(location: afterWord, length: length - afterWord)
                ) else { continue }
                let valueStart = NSMaxRange(assignment.range)
                let closingQuote = nsText.rangeOfCharacter(
                    from: quotes,
                    options: .literal,
                    range: NSRange(location: valueStart, length: length - valueStart)
                )
                guard closingQuote.location != NSNotFound,
                      hidingRegex.firstMatch(
                        in: text,
                        options: [],
                        range: NSRange(location: valueStart, length: closingQuote.location - valueStart)
                      ) != nil else { continue }
                let afterQuote = closingQuote.location + 1
                let elementEnd: Int?
                if let knownTagEnd, afterQuote >= knownTagEnd.from,
                   knownTagEnd.at.map({ afterQuote <= $0 }) ?? true {
                    elementEnd = knownTagEnd.at
                } else {
                    let found = nsText.range(
                        of: ">",
                        options: .literal,
                        range: NSRange(location: afterQuote, length: length - afterQuote)
                    )
                    elementEnd = found.location == NSNotFound ? nil : found.location
                    knownTagEnd = (from: afterQuote, at: elementEnd)
                }
                if let elementEnd {
                    styles.append(Style(location: word.range.location, elementEnd: elementEnd))
                }
            }
            self.styles = styles
        }

        subscript(index: Int) -> Style { styles[index] }

        /// The hiding `style`s in `[location, end)`.
        func indices(atOrAfter location: Int, before end: Int) -> Range<Int> {
            let lower = firstIndex { $0.location >= location }
            let upper = firstIndex { $0.location >= end }
            return lower..<max(lower, upper)
        }

        /// The last index in `range` whose style satisfies `predicate`, which
        /// holds for a prefix of the styles in order.
        func lastIndex(in range: Range<Int>, where predicate: (Style) -> Bool) -> Int? {
            var low = range.lowerBound
            var high = range.upperBound
            while low < high {
                let middle = (low + high) / 2
                if predicate(styles[middle]) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low > range.lowerBound ? low - 1 : nil
        }

        /// The first index whose style satisfies `predicate`, which holds for
        /// a suffix of the styles in order.
        private func firstIndex(where predicate: (Style) -> Bool) -> Int {
            var low = 0
            var high = styles.count
            while low < high {
                let middle = (low + high) / 2
                if predicate(styles[middle]) {
                    high = middle
                } else {
                    low = middle + 1
                }
            }
            return low
        }
    }

    /// Every `</name>`, by name.
    private struct CloseTagPositions {
        enum Closes {
            /// The name's close tags, in order.
            case indexed(SortedCloses)
            /// A name, or a text, the regex's case folding has to judge.
            case leftToTheRegex
        }

        /// Close tags in order, with a binary search for the first after a
        /// location.
        struct SortedCloses {
            fileprivate let ranges: [NSRange]

            var last: NSRange? { ranges.last }

            func first(where isAfter: (NSRange) -> Bool) -> NSRange? {
                var low = 0
                var high = ranges.count
                while low < high {
                    let middle = (low + high) / 2
                    if isAfter(ranges[middle]) {
                        high = middle
                    } else {
                        low = middle + 1
                    }
                }
                return low < ranges.count ? ranges[low] : nil
            }
        }

        private var rangesByName: [String: [NSRange]] = [:]
        /// Whether some close tag's name holds a character outside ASCII.
        private var hasUnfoldedName = false

        init(_ text: String) {
            guard let closeTagRegex = HTMLMarkupScan.closeTagRegex else {
                hasUnfoldedName = true
                return
            }
            let nsText = text as NSString
            for match in closeTagRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                if let key = Self.key(nsText.substring(with: match.range(at: 1))) {
                    rangesByName[key, default: []].append(match.range)
                } else {
                    hasUnfoldedName = true
                }
            }
        }

        /// ASCII names compare ignoring ASCII case; nil for any other.
        private static func key(_ name: String) -> String? {
            name.utf16.allSatisfy { $0 < 0x80 } ? name.lowercased() : nil
        }

        func closes(forName name: String) -> Closes {
            guard !hasUnfoldedName, let key = Self.key(name) else { return .leftToTheRegex }
            return .indexed(SortedCloses(ranges: rangesByName[key] ?? []))
        }
    }
}
