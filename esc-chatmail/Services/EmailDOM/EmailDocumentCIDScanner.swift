import Foundation

// MARK: - Shared regex-free `cid:` scanner

extension EmailDocument {

    /// Characters that terminate a `cid:` identifier during a regex-free scan of raw
    /// HTML. Each historical call site used a slightly different set, so the variants
    /// are named here to keep their scanning behavior identical after consolidating
    /// onto ``scanReferencedContentIDs(in:terminators:handle:)``.
    enum CIDScanTerminators {
        /// Stops at attribute delimiters: `"`, `'`, space, `,`, `>`, `<`.
        /// Use when scanning attribute values such as `src="cid:…"`.
        static let attribute: Set<Character> = ["\"", "'", " ", ",", ">", "<"]

        /// ``attribute`` plus `)`, for CSS `url(cid:…)` forms.
        static let css: Set<Character> = ["\"", "'", " ", ",", ")", ">", "<"]

        /// ``css`` plus raw whitespace (`\n`, `\r`, `\t`).
        static let cssAndWhitespace: Set<Character> = ["\"", "'", " ", ",", ")", ">", "<", "\n", "\r", "\t"]
    }

    /// Scans `html` for `cid:` references (case-insensitive) and invokes `handle`
    /// once per reference with the normalized Content-ID and the index at which the
    /// identifier value begins (immediately after `cid:`). The identifier runs from
    /// that index up to the first character contained in `terminators`. References
    /// whose value is empty or fails ``normalizedContentID(_:)`` are skipped.
    ///
    /// This is the single regex-free CID scanner shared by the message, bubble, and
    /// web-view layers. Callers that only need the set of identifiers should use
    /// ``referencedContentIDs(in:terminators:)``; the start index is exposed for
    /// callers that key heuristics off where in the document a reference appears.
    static func scanReferencedContentIDs(
        in html: String,
        terminators: Set<Character> = CIDScanTerminators.attribute,
        handle: (_ contentID: String, _ valueStart: String.Index) -> Void
    ) {
        let cidScheme = "cid:"
        var searchRange = html.startIndex..<html.endIndex

        while let cidRange = html.range(of: cidScheme, options: .caseInsensitive, range: searchRange) {
            let valueStart = cidRange.upperBound
            var valueEnd = valueStart
            while valueEnd < html.endIndex, !terminators.contains(html[valueEnd]) {
                valueEnd = html.index(after: valueEnd)
            }

            if valueStart < valueEnd,
               let contentID = normalizedContentID(String(html[valueStart..<valueEnd])) {
                handle(contentID, valueStart)
            }

            searchRange = valueEnd..<html.endIndex
        }
    }

    /// Collects the set of normalized `cid:` references in `html`. Thin convenience
    /// over ``scanReferencedContentIDs(in:terminators:handle:)`` for the common
    /// "I just need the identifiers" case.
    static func referencedContentIDs(
        in html: String,
        terminators: Set<Character> = CIDScanTerminators.attribute
    ) -> Set<String> {
        var result = Set<String>()
        scanReferencedContentIDs(in: html, terminators: terminators) { contentID, _ in
            result.insert(contentID)
        }
        return result
    }
}
