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
    /// - Otherwise text → paste it. Cells copied from a spreadsheet, and an image copied
    ///   from a web page, carry a picture and words together, and in a text field the words
    ///   are what is meant.
    /// - Otherwise an image → attach it: a screenshot taken to the clipboard, a selection
    ///   copied in Preview.
    /// - Otherwise the field's own paste, which pastes nothing.
    static func action(carriesFiles: Bool, carriesText: Bool, carriesImage: Bool) -> Action {
        if carriesFiles { return .attachFiles }
        if carriesText { return .pasteAsText }
        return carriesImage ? .attachImage : .pasteAsText
    }
}
