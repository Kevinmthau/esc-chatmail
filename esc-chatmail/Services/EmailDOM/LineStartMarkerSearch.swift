import Foundation

/// The earliest match of any of `(?:^|[\r\n])\s*marker` (case-insensitive), as
/// that regex finds it, read once.
///
/// The regex's `\s*` crosses newlines, so at every newline of a run of blank
/// lines it read the rest of the run before failing on what followed, and a
/// run of n blank lines cost n²: 8,000 of them (23 KB) held each received
/// message's HTML cleanup for 30 s (`EmailDOMQuoteRemover+TextMarkers`).
///
/// Every marker starts with a character that is not whitespace, so `\s*` has
/// to take the whole run of whitespace after its start, and every start in
/// one run matches exactly when the run's first start does: at the text's
/// start, or at the run's first `\r` or `\n`. The regex then takes that first
/// start, through the end of the marker's own match. Here each run's first
/// start is tried once: the marker is matched where the run ends.
/// `LineStartMarkerSearchTests` compares this with the regex.
struct LineStartMarkerSearch {
    /// Each marker's own regex, anchored where it is tried.
    private let markers: [NSRegularExpression]

    /// Each marker must start with a character that is not whitespace.
    init(markers: [String]) {
        self.markers = markers.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }

    private static let whitespaceRunRegex = try? NSRegularExpression(pattern: "\\s+", options: [])

    /// The earliest match of any marker's regex, the shorter of two that
    /// start together, as the regexes' `firstMatch` and that order gave.
    func earliestMatch(in text: String) -> NSRange? {
        let nsText = text as NSString
        let length = nsText.length
        var earliest: NSRange?
        func consider(start: Int, markerAt location: Int) -> Bool {
            var found = false
            for marker in markers {
                guard let match = marker.firstMatch(
                    in: text,
                    options: .anchored,
                    range: NSRange(location: location, length: length - location)
                ) else { continue }
                let range = NSRange(location: start, length: NSMaxRange(match.range) - start)
                if earliest.map({ range.length < $0.length }) ?? true {
                    earliest = range
                }
                found = true
            }
            return found
        }

        // At the text's start with no whitespace before the marker.
        if length > 0, !Self.isWhitespace(at: 0, in: text),
           consider(start: 0, markerAt: 0) {
            return earliest
        }
        guard let whitespaceRunRegex = Self.whitespaceRunRegex else { return nil }
        var searchFrom = 0
        while searchFrom < length,
              let run = whitespaceRunRegex.firstMatch(
                in: text,
                options: [],
                range: NSRange(location: searchFrom, length: length - searchFrom)
              ) {
            let runEnd = NSMaxRange(run.range)
            searchFrom = runEnd
            guard runEnd < length else { break }
            let start: Int
            if run.range.location == 0 {
                start = 0
            } else {
                let lineBreak = nsText.rangeOfCharacter(
                    from: Self.lineBreaks,
                    options: .literal,
                    range: run.range
                )
                guard lineBreak.location != NSNotFound else { continue }
                start = lineBreak.location
            }
            if consider(start: start, markerAt: runEnd) {
                return earliest
            }
        }
        return nil
    }

    private static let lineBreaks = CharacterSet(charactersIn: "\r\n")

    private static func isWhitespace(at location: Int, in text: String) -> Bool {
        guard let whitespaceRunRegex else { return false }
        return whitespaceRunRegex.firstMatch(
            in: text,
            options: .anchored,
            range: NSRange(location: location, length: (text as NSString).length - location)
        ) != nil
    }
}
