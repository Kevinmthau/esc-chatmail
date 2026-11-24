import Foundation

/// An element an attribute hides, removed through its close tag, linearly:
/// what a regex of the shape
/// `<(NAME)\b[^>]*ATTRIBUTE[^>]*>[\s\S]*?</\1>` (case-insensitive) removed,
/// where ATTRIBUTE is either a bare word (`\bhidden\b`) or a quoted value
/// holding a declaration (`style\s*=\s*['"][^'"]*(?:display\s*:\s*none|…)[^'"]*['"]`).
///
/// The regex tried every `<name` and, at each, read to the tag's `>` and
/// through every attribute before it, and from each tag end it could take to
/// the end of the text for a close tag: a sender's `<div style="a` repeated
/// 8,000 times (101 KB) held a message's snippet for 35 s, and an attribute
/// value holding `<a style='display:none'>` 5,000 times (SwiftSoup writes `<`
/// and `>` in attribute values back out as they came) held each cleanup
/// mode's meaningful-content check for 8 s at 120 KB.
///
/// Here each `<name`'s match is worked out from indexes built once, with the
/// regex's result. A bare attribute cannot hold a `>`, so the tag ends at its
/// first `>`, and the element ends at the first close tag of its name after
/// that. A quoted value can: a value that hides the element ends the tag at
/// the first `>` after the value's closing quote. The regex tries the last
/// such attribute before the tag's first `>` first, then each earlier one, and
/// takes the first whose end has a close tag of the name after it, through
/// the first such close tag. Those ends never decrease from one attribute to
/// the next (a value holds no quote, so a later attribute's value starts at or
/// after an earlier one's closing quote), so the attributes with a close tag
/// after their end come first, and the regex takes the last of them.
///
/// One difference, deliberate: a name is matched to its close tag ignoring
/// ASCII case only. The regex's backreference folded case fully, so `<ss`
/// closed at `</ß>`, `<st` at `</ﬆ>`, and a name spelled with `ſ` or the
/// Kelvin sign at its ASCII spelling. Such a close tag ends nothing here: the
/// element is left in place, or, where a close tag of its name in ASCII
/// follows, removed through that one (`<s hidden>a</ſ>b</s>c` leaves `c`
/// where the regex left `b</s>c`). Handing those names back to the regex kept it quadratic for a whole message
/// whenever one such character appeared (`HTMLMarkupScanTests` pins the
/// difference and compares the rest with each regex).
struct HiddenElementRule {
    enum Attribute {
        /// A word anywhere in the tag (`\bhidden\b`).
        case bare(NSRegularExpression)
        /// `word\s*=\s*['"]`, then a value that holds `declaration` and no quote.
        case quoted(word: NSRegularExpression, declaration: NSRegularExpression)
    }

    let elementStart: NSRegularExpression
    let attribute: Attribute

    /// `MessageProcessor.prepareHTMLForSnippet`'s rule:
    /// `<([a-zA-Z0-9]+)\b[^>]*style\s*=\s*['"][^'"]*(?:display\s*:\s*none|visibility\s*:\s*hidden|mso-hide\s*:\s*all|max-height\s*:\s*0|opacity\s*:\s*0|font-size\s*:\s*0)[^'"]*['"][^>]*>[\s\S]*?</\1>`.
    static let snippet = HiddenElementRule(
        elementStart: "<([a-zA-Z0-9]+)\\b",
        quotedWord: "style",
        declaration: "display\\s*:\\s*none|visibility\\s*:\\s*hidden|mso-hide\\s*:\\s*all|max-height\\s*:\\s*0|opacity\\s*:\\s*0|font-size\\s*:\\s*0"
    )

    /// `HTMLMeaningfulContentChecker`'s three rules, in its order: an explicit
    /// `hidden` attribute; a style that does not render (not `font-size:0` or
    /// `line-height:0` alone, which table templates put on visible wrappers);
    /// the hidden-class conventions of email templates. Each is
    /// `<([a-zA-Z][a-zA-Z0-9]*)\b[^>]*ATTRIBUTE[^>]*>[\s\S]*?</\1>`.
    static let meaningfulContentRules: [HiddenElementRule] = ([
        HiddenElementRule(elementStart: "<([a-zA-Z][a-zA-Z0-9]*)\\b", bareWord: "\\bhidden\\b"),
        HiddenElementRule(
            elementStart: "<([a-zA-Z][a-zA-Z0-9]*)\\b",
            quotedWord: "style",
            declaration: "display\\s*:\\s*none|visibility\\s*:\\s*hidden|mso-hide\\s*:\\s*all|opacity\\s*:\\s*0(?:\\.0+)?"
        ),
        HiddenElementRule(
            elementStart: "<([a-zA-Z][a-zA-Z0-9]*)\\b",
            quotedWord: "class",
            declaration: "\\bm-hide\\b|\\bpreheader\\b|\\bpreview-text\\b"
        ),
    ] as [HiddenElementRule?]).compactMap { $0 }

    init?(elementStart: String, bareWord: String) {
        guard let start = try? NSRegularExpression(pattern: elementStart, options: [.caseInsensitive]),
              let word = try? NSRegularExpression(pattern: bareWord, options: [.caseInsensitive]) else {
            return nil
        }
        self.elementStart = start
        self.attribute = .bare(word)
    }

    init?(elementStart: String, quotedWord: String, declaration: String) {
        guard let start = try? NSRegularExpression(pattern: elementStart, options: [.caseInsensitive]),
              let word = try? NSRegularExpression(pattern: quotedWord, options: [.caseInsensitive]),
              let declaration = try? NSRegularExpression(pattern: declaration, options: [.caseInsensitive]) else {
            return nil
        }
        self.elementStart = start
        self.attribute = .quoted(word: word, declaration: declaration)
    }

    private static let assignmentRegex = try? NSRegularExpression(pattern: "\\s*=\\s*['\"]", options: [.caseInsensitive])
    private static let closeTagRegex = try? NSRegularExpression(pattern: "</([a-zA-Z0-9]+)>", options: [.caseInsensitive])

    /// Every element this rule hides removed, with its close tag.
    func removing(from text: String) -> String {
        let nsText = text as NSString
        let length = nsText.length
        let attributes = AttributeIndex(text, attribute: attribute)
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
              let start = elementStart.firstMatch(
                in: text,
                options: [],
                range: NSRange(location: searchFrom, length: length - searchFrom)
              ) {
            let nameEnd = NSMaxRange(start.range)
            guard let tagEnd = firstTagEnd(from: nameEnd) else { break }
            let candidates = attributes.indices(atOrAfter: nameEnd, before: tagEnd)
            var matchEnd: Int?
            if !candidates.isEmpty,
               let closes = closeTags.closes(forName: nsText.substring(with: start.range(at: 1))),
               let lastClose = closes.last?.location,
               let lastWithClose = attributes.lastIndex(in: candidates, where: { $0.elementEnd < lastClose }) {
                let elementEnd = attributes[lastWithClose].elementEnd
                matchEnd = closes.first { $0.location > elementEnd }.map(NSMaxRange)
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

    /// Every place the attribute can be, in order, with the `>` an element's
    /// tag would end at if the regex took it there.
    private struct AttributeIndex {
        struct Entry {
            let location: Int
            let elementEnd: Int
        }

        private let entries: [Entry]

        init(_ text: String, attribute: Attribute) {
            let nsText = text as NSString
            let length = nsText.length
            var entries: [Entry] = []
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

            switch attribute {
            case .bare(let word):
                // A bare word holds no `>`: the tag ends at its first one.
                for match in word.matches(in: text, range: NSRange(location: 0, length: length)) {
                    if let elementEnd = firstTagEnd(from: match.range.location) {
                        entries.append(Entry(location: match.range.location, elementEnd: elementEnd))
                    }
                }
            case .quoted(let word, let declaration):
                guard let assignmentRegex = HiddenElementRule.assignmentRegex else { break }
                let quotes = CharacterSet(charactersIn: "'\"")
                var searchFrom = 0
                while searchFrom < length,
                      let found = word.firstMatch(
                        in: text,
                        options: [],
                        range: NSRange(location: searchFrom, length: length - searchFrom)
                      ) {
                    searchFrom = found.range.location + 1
                    let afterWord = NSMaxRange(found.range)
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
                    // Transparent bounds: a `\b` at the value's edge reads the
                    // quote beside it, as the whole regex did.
                    guard closingQuote.location != NSNotFound,
                          declaration.firstMatch(
                            in: text,
                            options: .withTransparentBounds,
                            range: NSRange(location: valueStart, length: closingQuote.location - valueStart)
                          ) != nil,
                          let elementEnd = firstTagEnd(from: closingQuote.location + 1) else { continue }
                    entries.append(Entry(location: found.range.location, elementEnd: elementEnd))
                }
            }
            self.entries = entries
        }

        subscript(index: Int) -> Entry { entries[index] }

        /// The entries in `[location, end)`.
        func indices(atOrAfter location: Int, before end: Int) -> Range<Int> {
            let lower = firstIndex { $0.location >= location }
            let upper = firstIndex { $0.location >= end }
            return lower..<max(lower, upper)
        }

        /// The last index in `range` whose entry satisfies `predicate`, which
        /// holds for a prefix of the entries in order.
        func lastIndex(in range: Range<Int>, where predicate: (Entry) -> Bool) -> Int? {
            var low = range.lowerBound
            var high = range.upperBound
            while low < high {
                let middle = (low + high) / 2
                if predicate(entries[middle]) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low > range.lowerBound ? low - 1 : nil
        }

        /// The first index whose entry satisfies `predicate`, which holds for
        /// a suffix of the entries in order.
        private func firstIndex(where predicate: (Entry) -> Bool) -> Int {
            var low = 0
            var high = entries.count
            while low < high {
                let middle = (low + high) / 2
                if predicate(entries[middle]) {
                    high = middle
                } else {
                    low = middle + 1
                }
            }
            return low
        }
    }

    /// Every `</name>` whose name is ASCII, by name ignoring ASCII case.
    private struct CloseTagPositions {
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

        init(_ text: String) {
            guard let closeTagRegex = HiddenElementRule.closeTagRegex else { return }
            let nsText = text as NSString
            for match in closeTagRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                if let key = Self.key(nsText.substring(with: match.range(at: 1))) {
                    rangesByName[key, default: []].append(match.range)
                }
            }
        }

        /// ASCII names compare ignoring ASCII case; nil for any other.
        private static func key(_ name: String) -> String? {
            name.utf16.allSatisfy { $0 < 0x80 } ? name.lowercased() : nil
        }

        /// Nil for a name outside ASCII, which closes nothing.
        func closes(forName name: String) -> SortedCloses? {
            Self.key(name).map { SortedCloses(ranges: rangesByName[$0] ?? []) }
        }
    }
}
