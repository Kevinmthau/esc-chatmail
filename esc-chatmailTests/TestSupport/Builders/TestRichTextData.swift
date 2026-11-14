#if os(macOS)
import AppKit
import XCTest

/// Rich text that holds files (RTFD), as a pasteboard carries it, for the tests of what the
/// Mac's reply field pastes. Built with AppKit as a text view builds its own copy.
enum TestRichTextData {
    enum Part {
        case words(String)
        /// A file attached in the text, under the name it had where it was copied.
        case file(Data, named: String)
    }

    /// `parts` as RTFD, in order.
    static func rtfd(_ parts: [Part]) throws -> Data {
        let text = NSMutableAttributedString()
        for part in parts {
            switch part {
            case .words(let words):
                text.append(NSAttributedString(string: words))
            case .file(let data, let name):
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = name
                text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            }
        }
        return try XCTUnwrap(
            text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]),
            "AppKit could not write the RTFD"
        )
    }

    /// The plain text a text view writes beside such rich text: the words, with the mark
    /// that stands for a file where each one is (U+FFFC).
    static func plainText(_ parts: [Part]) -> String {
        parts.map { part in
            switch part {
            case .words(let words): return words
            case .file: return "\u{FFFC}"
            }
        }
        .joined()
    }
}
#endif
