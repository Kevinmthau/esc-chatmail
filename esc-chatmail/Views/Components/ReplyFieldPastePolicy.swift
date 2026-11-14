import Foundation

/// What Paste does in the Mac's reply field (`MacReplyTextView`), decided from what the
/// pasteboard carries.
enum ReplyFieldPastePolicy {
    enum Action: Equatable {
        /// The copied files are attached to the reply, as files dropped on the chat are.
        case attachFiles
        /// The copied image is attached to the reply.
        case attachImage
        /// The field pastes as a text view does: text, or nothing.
        case pasteAsText
    }

    /// - Files → attach them. A file copied in the Finder also puts its name on the
    ///   pasteboard as text, and a text view pastes a copied file as its path (measured on
    ///   this field, 2026-11-12), so files are asked about first. In a reply a copied file
    ///   means the file.
    /// - Otherwise an image with no text → attach it: a screenshot taken to the clipboard, a
    ///   selection copied in Preview.
    /// - Otherwise an image whose only text is its own address → attach it
    ///   (`textIsOnlyTheAddress`). Copy Image in a web view writes the picture and, as text,
    ///   where it came from; pasted as text, the reply got the address and no picture.
    /// - Otherwise text → paste it. Cells copied from a spreadsheet carry a picture and words
    ///   together, and in a text field the words are what is meant.
    /// - Otherwise the field's own paste, which pastes nothing.
    ///
    /// - Parameter textIsOnlyTheCopiedAddress: `textIsOnlyTheAddress` of the pasteboard's
    ///   text and URL. Asked only where a picture and text were copied together and no file:
    ///   answering it reads the text, which can be long, and nothing is read that need not
    ///   be. It is a paste that asks this; the Edit menu's validation never does
    ///   (`fieldEnablesPaste`).
    static func action(
        carriesFiles: Bool,
        carriesText: Bool,
        carriesImage: Bool,
        textIsOnlyTheCopiedAddress: @autoclosure () -> Bool
    ) -> Action {
        if carriesFiles { return .attachFiles }
        guard carriesImage else { return .pasteAsText }
        guard carriesText else { return .attachImage }
        return textIsOnlyTheCopiedAddress() ? .attachImage : .pasteAsText
    }

    /// Whether the field enables Paste by its own rule (`MacReplyTextView.enablesPasteItself`):
    /// for files, and for a picture copied with no text. Everything else is the text view's
    /// own to answer.
    ///
    /// Decided from the kinds the pasteboard has, and never from its text. This is asked at
    /// every validation of the Edit menu, which is not a paste, and what the text is can
    /// only be found by reading it. The answer does not need it: with text on the pasteboard
    /// the text view enables Paste itself, whatever Paste then does, so a picture copied
    /// with its address is enabled either way. As first written the validation read the text
    /// and the URL (review of PR 422, 2026-11-14): megabytes of them for a picture with a
    /// `data:` address, at every validation, and a read of the general pasteboard that no
    /// paste asked for. Apple's notes for AppKit say macOS alerts the user to such a read;
    /// whether macOS 27 does was not measured.
    static func fieldEnablesPaste(carriesFiles: Bool, carriesText: Bool, carriesImage: Bool) -> Bool {
        action(
            carriesFiles: carriesFiles,
            carriesText: carriesText,
            carriesImage: carriesImage,
            textIsOnlyTheCopiedAddress: false
        ) != .pasteAsText
    }

    /// Whether a pasteboard's text is the URL the pasteboard carries and nothing more, which
    /// is what Copy Image leaves beside the picture.
    ///
    /// Read from WebKit's source (2026-11-14), not measured: Copy Image writes one string,
    /// the address in the form shown to the user, as the pasteboard's text and as its
    /// `public.url` alike, whatever the address's scheme. So the two are compared as they
    /// are, with only the white space around them dropped, and no scheme is asked for: a
    /// picture a page holds inline has a `data:` address, which is the whole picture again as
    /// text. What Safari itself puts on the pasteboard has not been looked at.
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
}
