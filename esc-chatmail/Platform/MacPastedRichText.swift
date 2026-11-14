#if os(macOS)
import AppKit

/// The files held by rich text on a pasteboard (RTFD), for a paste into the reply field
/// (`MacReplyTextView`).
///
/// Two things are copied this way, both measured 2026-11-14 on pasteboards of a probe's own:
/// - **A picture selected in a rich text view.** The pasteboard has RTFD, RTF and, as plain
///   text, the mark that stands for the picture (`ReplyFieldPastePolicy.pictureMark`). It has
///   no TIFF and no PNG, so the picture is nowhere but in the RTFD.
/// - **Copy Image in a web view.** Beside the TIFF, the RTFD holds one file and nothing
///   else, and that file is the page's own, byte for byte: 0.74 MB for a JPEG whose TIFF was
///   27 MB. So the picture is taken from here before the TIFF is read.
enum MacPastedRichText {
    /// What the RTFD on a pasteboard holds.
    struct Contents {
        /// The contents of each file attached in it, in the text's order. A folder attached
        /// in it has none and is left out.
        let attachedFiles: [Data]
        /// Whether it holds anything but attached files and white space.
        let hasWords: Bool
    }

    /// The contents of the RTFD on `pasteboard`, or nil where it has none that can be read.
    /// This reads the RTFD, so it is for a paste and never for validating one.
    static func contents(on pasteboard: NSPasteboard) -> Contents? {
        guard let data = pasteboard.data(forType: .rtfd),
              let text = NSAttributedString(rtfd: data, documentAttributes: nil) else {
            return nil
        }
        var attachedFiles: [Data] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment,
                  let wrapper = attachment.fileWrapper, wrapper.isRegularFile,
                  let contents = wrapper.regularFileContents else {
                return
            }
            attachedFiles.append(contents)
        }
        let hasWords = text.string.unicodeScalars.contains {
            $0 != ReplyFieldPastePolicy.pictureMark && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return Contents(attachedFiles: attachedFiles, hasWords: hasWords)
    }

    /// The pictures attached in the RTFD on `pasteboard`, each in a form the draft's import
    /// takes (`PastedImageEncoder.attachable`). A file in it that is no picture is left out.
    static func pictures(on pasteboard: NSPasteboard) -> [PastedImageEncoder.Attachable] {
        contents(on: pasteboard)?.attachedFiles.compactMap(PastedImageEncoder.attachable(from:)) ?? []
    }

    /// The one picture the RTFD on `pasteboard` is, where it is one file and nothing else:
    /// the file behind a picture the pasteboard also has as a bitmap. Nil where the RTFD
    /// holds words or more than one file, which is rich text that was copied, not a picture.
    static func solePicture(on pasteboard: NSPasteboard) -> PastedImageEncoder.Attachable? {
        guard let contents = contents(on: pasteboard), !contents.hasWords,
              contents.attachedFiles.count == 1, let file = contents.attachedFiles.first else {
            return nil
        }
        return PastedImageEncoder.attachable(from: file)
    }
}
#endif
