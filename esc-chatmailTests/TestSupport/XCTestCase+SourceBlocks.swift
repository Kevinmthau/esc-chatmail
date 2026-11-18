import XCTest

extension XCTestCase {
    /// Where the text between the first `open` at or after `marker` in `text` and its matching
    /// `close` is: the body of a call's parentheses or a closure's braces, for a suite that pins
    /// something from source text (read with `repositorySource(_:)`). Its `upperBound` is that
    /// `close`.
    ///
    /// Counts nesting of that one pair only, and does not skip comments or string literals: a
    /// suite uses it on Swift that has neither the pair inside a string nor in a comment within
    /// the block. `ChatComposerStyleSourceTests`, `ChatHeaderStyleSourceTests` and
    /// `LogRedactionTests` still have readers of their own.
    ///
    /// A marker that ends with `open` (`"confirmationDialog("`, `"List {"`) opens the block
    /// itself: the body starts right after it. Read as a marker to search on from, it found
    /// the next `open` instead, the first nested block, and a block that ended early (a
    /// `List {` read as its first `if` passed a check it should have failed).
    ///
    /// - Parameters:
    ///   - path: The file `text` was read from, named in every failure.
    ///   - openingIsInMarker: The marker holds `open` short of its end (`"{ name in"`), so the
    ///     body starts right after the marker. Not needed where the marker ends with `open`.
    func sourceBlockRange(
        after marker: String,
        open: Character,
        close: Character,
        in text: String,
        path: String,
        openingIsInMarker: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Range<String.Index> {
        let markerRange = try XCTUnwrap(
            text.range(of: marker),
            "\(path) no longer has `\(marker)`",
            file: file,
            line: line
        )
        let bodyStart: String.Index
        if openingIsInMarker || marker.last == open {
            bodyStart = markerRange.upperBound
        } else {
            let opening = try XCTUnwrap(
                text[markerRange.upperBound...].firstIndex(of: open),
                "\(path): nothing opens with `\(open)` after `\(marker)`",
                file: file,
                line: line
            )
            bodyStart = text.index(after: opening)
        }
        var depth = 1
        var index = bodyStart
        while index < text.endIndex {
            let character = text[index]
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 {
                    return bodyStart..<index
                }
            }
            index = text.index(after: index)
        }
        return try XCTUnwrap(
            nil as Range<String.Index>?,
            "\(path): `\(marker)` is never closed with `\(close)`",
            file: file,
            line: line
        )
    }

    /// The text `sourceBlockRange` finds.
    func sourceBlock(
        after marker: String,
        open: Character,
        close: Character,
        in text: String,
        path: String,
        openingIsInMarker: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        String(text[try sourceBlockRange(
            after: marker,
            open: open,
            close: close,
            in: text,
            path: path,
            openingIsInMarker: openingIsInMarker,
            file: file,
            line: line
        )])
    }
}
