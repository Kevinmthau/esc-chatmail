import Foundation

/// What Paste does in the Mac's reply field (`MacReplyTextView`), decided from what the
/// pasteboard carries.
enum ReplyFieldPastePolicy {
    enum Action: Equatable {
        /// The copied files are attached to the reply, as files dropped on the chat are.
        case attachFiles
        /// The copied image is attached to the reply.
        case attachImage
        /// The pictures in the copied rich text are attached to the reply. It holds nothing
        /// else, and the pasteboard has no picture apart from it.
        case attachPicturesInRichText
        /// The copied text is pasted without the marks that stand where its pictures were
        /// (`removingPictureMarks`).
        case pasteTextWithoutPictureMarks
        /// The field pastes as a text view does: text, or nothing.
        case pasteAsText
    }

    /// What the text copied with rich text has of the marks that stand for its pictures
    /// (`pictureMarks(in:)`).
    enum PictureMarks: Equatable {
        /// No mark: the text is words.
        case none
        /// Marks and white space and nothing else: what was copied is pictures.
        case only
        /// Marks among words.
        case amongWords
    }

    /// - Files → attach them. A file copied in the Finder also puts its name on the
    ///   pasteboard as text, and a text view pastes a copied file as its path (measured on
    ///   this field, 2026-11-12), so files are asked about first. In a reply a copied file
    ///   means the file.
    /// - Otherwise an image with no text → attach it: a screenshot taken to the clipboard, a
    ///   selection copied in Preview, and a picture copied in a web view, which writes no
    ///   text with it (`textIsOnlyTheAddress`).
    /// - Otherwise an image whose only text is its own address → attach it
    ///   (`textIsOnlyTheAddress`).
    /// - Otherwise text copied with rich text that can hold pictures (RTFD), where the text
    ///   has the marks that stand for them (`pictureMarks(in:)`). Marks and nothing else →
    ///   the pictures are what was copied, and they are attached: the pasteboard's own image
    ///   where it has one, the ones in the rich text where it has none. Marks among words →
    ///   the words are pasted without the marks. A text view pastes a mark as a character
    ///   (measured 2026-11-14 on a text view set up as this field is: it read U+FFFC into its
    ///   text), which is sent as part of the mail and stands for nothing there.
    /// - Otherwise text → paste it. Cells copied from a spreadsheet carry a picture and words
    ///   together, and in a text field the words are what is meant.
    /// - Otherwise the field's own paste, which pastes nothing.
    ///
    /// - Parameters:
    ///   - carriesRichTextWithAttachments: The pasteboard says it has RTFD, the rich text
    ///     that holds files.
    ///   - textIsOnlyTheCopiedAddress: `textIsOnlyTheAddress` of the pasteboard's text and
    ///     URL. Asked only where a picture and text were copied together and no file.
    ///   - pictureMarksInText: `pictureMarks(in:)` of the pasteboard's text. Asked only where
    ///     text and RTFD were copied together and no file.
    ///
    /// Answering either of the last two reads the text, which can be long, and nothing is
    /// read that need not be. It is a paste that asks them; the Edit menu's validation never
    /// does (`fieldEnablesPaste`).
    static func action(
        carriesFiles: Bool,
        carriesText: Bool,
        carriesImage: Bool,
        carriesRichTextWithAttachments: Bool,
        textIsOnlyTheCopiedAddress: @autoclosure () -> Bool,
        pictureMarksInText: @autoclosure () -> PictureMarks
    ) -> Action {
        if carriesFiles { return .attachFiles }
        guard carriesText else { return carriesImage ? .attachImage : .pasteAsText }
        if carriesImage, textIsOnlyTheCopiedAddress() { return .attachImage }
        guard carriesRichTextWithAttachments else { return .pasteAsText }
        switch pictureMarksInText() {
        case .none:
            return .pasteAsText
        case .only:
            return carriesImage ? .attachImage : .attachPicturesInRichText
        case .amongWords:
            return .pasteTextWithoutPictureMarks
        }
    }

    /// Whether the field enables Paste by its own rule (`MacReplyTextView.enablesPasteItself`):
    /// for files, and for a picture copied with no text. Everything else is the text view's
    /// own to answer.
    ///
    /// Decided from the kinds the pasteboard has, and never from its text. This is asked at
    /// every validation of the Edit menu, which is not a paste, and what the text is can
    /// only be found by reading it. The answer does not need it: with text on the pasteboard
    /// the text view enables Paste itself, whatever Paste then does, so a picture copied
    /// with its address, and pictures copied as rich text, are enabled either way. As first
    /// written the validation read the text and the URL (review of PR 422, 2026-11-14):
    /// megabytes of them for a picture with a `data:` address, at every validation, and a
    /// read of the general pasteboard that no paste asked for. Apple's notes for AppKit say
    /// macOS alerts the user to such a read; whether macOS 27 does was not measured.
    static func fieldEnablesPaste(carriesFiles: Bool, carriesText: Bool, carriesImage: Bool) -> Bool {
        action(
            carriesFiles: carriesFiles,
            carriesText: carriesText,
            carriesImage: carriesImage,
            carriesRichTextWithAttachments: false,
            textIsOnlyTheCopiedAddress: false,
            pictureMarksInText: .none
        ) != .pasteAsText
    }

    /// Whether the field takes a paste at all, of text as of anything else: not while its
    /// window has a sheet attached.
    ///
    /// The chat already refused files and pictures pasted behind a sheet
    /// (`DraftFileDropPolicy.takesPaste`), and Paste stayed enabled for them and beeped,
    /// while text was still typed into the draft behind the sheet, unseen (review of PR 422,
    /// 2026-11-14). Now the command is disabled there and a paste that arrives anyway is
    /// refused, whatever was copied. That Command-V reaches the field behind a sheet is read
    /// from AppKit's rule for where a command goes, not measured.
    static func fieldTakesPaste(windowHasSheet: Bool) -> Bool {
        !windowHasSheet
    }

    /// Whether a pasteboard's text is the URL the pasteboard carries and nothing more.
    ///
    /// Written for Copy Image in a web view, on a reading of WebKit's source that was wrong:
    /// it was thought to write the picture's address as the pasteboard's text and its
    /// `public.url`. Measured 2026-11-14 on macOS 27.2.1, with Copy Image chosen in a
    /// `WKWebView` whose general pasteboard was replaced by one of the probe's own: it writes
    /// TIFF, RTFD, a web archive and HTML, and no text and no URL, for a JPEG, a PNG, a
    /// picture inside a link and one with a `data:` address alike. WebKit's source on `main`
    /// reads the same way (its image types are TIFF and RTFD). So a picture copied there is
    /// attached by the rule for a picture with no text, and this one is not reached.
    ///
    /// It is kept for a pasteboard that does carry a picture with its own address as its
    /// only text: the address adds nothing to the picture, and pasted as text the reply gets
    /// the address and no picture. No app is known to write one. The app runs on macOS 26
    /// too, whose WebKit was not measured. Safari's own pasteboard was not looked at either:
    /// it would mean reading what the user has copied.
    ///
    /// The two are compared as they are, with only the white space around them dropped, and
    /// no scheme is asked for: a picture a page holds inline has a `data:` address, which is
    /// the whole picture again as text.
    ///
    /// - Parameters:
    ///   - text: The pasteboard's text, nil where it has none.
    ///   - address: The pasteboard's URL as a string, nil where it carries none.
    static func textIsOnlyTheAddress(text: String?, address: String?) -> Bool {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let address = address?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return text == address
    }

    /// The character that stands in plain text where rich text has an attached file
    /// (U+FFFC, the object replacement character). Measured 2026-11-14: a text view's copy of
    /// one inline picture is RTFD and, as plain text, this character alone.
    static let pictureMark: Unicode.Scalar = "\u{FFFC}"

    /// What `text` has of picture marks: none, nothing but them and white space, or marks
    /// among words.
    ///
    /// Asked of Unicode scalars, not of `Character`s: a mark followed by a combining scalar
    /// is one `Character` that is not the mark.
    static func pictureMarks(in text: String?) -> PictureMarks {
        guard let text, text.unicodeScalars.contains(pictureMark) else { return .none }
        let hasWords = text.unicodeScalars.contains {
            $0 != pictureMark && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return hasWords ? .amongWords : .only
    }

    /// `text` without its picture marks, for a paste of words that were copied with
    /// pictures among them. The pictures are not attached: one copied by itself is.
    static func removingPictureMarks(from text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { $0 != pictureMark })
        return String(scalars)
    }
}
