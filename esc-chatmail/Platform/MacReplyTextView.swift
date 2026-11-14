#if os(macOS)
import AppKit

/// The text view inside the Mac's reply field (`MacReplyTextField`).
///
/// A subclass to report what a delegate is not told: that it gained or lost the keyboard
/// focus, and that it entered or left a window. The field's keys are decided by its delegate
/// (`MacReplyTextFieldCoordinator`, `ReplyFieldKeyPolicy`).
///
/// And to give away a drag of files. A text view takes one and types the file's path at the
/// pointer (measured on this field, 2026-11-12), which in a reply is never what a dropped file
/// means. The chat behind the field attaches it instead (`MacFileDropForwarder`); where there
/// is no chat to take it the drag is refused. A drag of text is the text view's own, as before.
final class MacReplyTextView: NSTextView {
    /// The view became (`true`) or stopped being (`false`) its window's first responder.
    var onFocusChange: ((Bool) -> Void)?
    /// The view entered a window (`true`) or left one (`false`).
    var onWindowChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { onFocusChange?(true) }
        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign { onFocusChange?(false) }
        return didResign
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window != nil)
    }

    // MARK: - Pasted files and images

    /// The pasteboard Paste reads. The tests give one of their own, so no test reads or
    /// writes what the user has copied.
    var pasteboardForPaste: () -> NSPasteboard = { .general }
    /// Where a pasted image's file is written (`PastedImageFile`). The tests give a
    /// directory of their own.
    var pastedImageDirectory: () -> URL = { PastedImageFile.directory() }
    /// Says that a paste was refused, so it does not look ignored. The tests record it.
    var refusePaste: () -> Void = { NSSound.beep() }

    /// A copied file is attached to the reply, and so is a copied picture where no words
    /// were copied with it (`ReplyFieldPastePolicy`). Left to the text view, a copied file is
    /// pasted as its path (measured on this field, 2026-11-12), a copied image as nothing,
    /// and a picture copied from rich text as the character that stands for it.
    override func paste(_ sender: Any?) {
        if !answerPaste() {
            super.paste(sender)
        }
    }

    /// Paste and Match Style is the same command for a field with one style.
    override func pasteAsPlainText(_ sender: Any?) {
        if !answerPaste() {
            super.pasteAsPlainText(sender)
        }
    }

    /// Does what the field itself does with a paste, and returns false for the one paste
    /// that is the text view's to make: text with no picture in it, into a window with no
    /// sheet attached. Both paste commands ask this before `super`.
    ///
    /// - Behind a sheet nothing is pasted, text included
    ///   (`ReplyFieldPastePolicy.fieldTakesPaste`).
    /// - Files and pictures are attached. A paste the chat cannot take now (a send owns the
    ///   draft, an import is running) is refused with a beep and is still answered here: the
    ///   text view must never be given a copied file to paste, or it types the path. The
    ///   same paste a moment later is taken, which is why nothing is typed in its place.
    /// - Words copied with pictures among them are pasted without the pictures' marks.
    func answerPaste() -> Bool {
        guard ReplyFieldPastePolicy.fieldTakesPaste(windowHasSheet: window?.attachedSheet != nil) else {
            refusePaste()
            return true
        }
        let pasteboard = pasteboardForPaste()
        switch Self.pasteAction(for: pasteboard) {
        case .pasteAsText:
            return false
        case .pasteTextWithoutPictureMarks:
            let text = pasteboard.string(forType: .string) ?? ""
            insertText(ReplyFieldPastePolicy.removingPictureMarks(from: text), replacementRange: selectedRange())
            return true
        case .attachFiles:
            let files = MacDraftFileDropView.fileURLs(on: pasteboard)
            if chatDropView?.receivePastedFiles(files) != true {
                refusePaste()
            }
            return true
        case .attachImage:
            if !attachPastedPictures({ Self.image(on: pasteboard).map { [$0] } ?? [] }) {
                refusePaste()
            }
            return true
        case .attachPicturesInRichText:
            if !attachPastedPictures({ MacPastedRichText.pictures(on: pasteboard) }) {
                refusePaste()
            }
            return true
        }
    }

    /// What Paste would do with `pasteboard` (`ReplyFieldPastePolicy`). Asked by a paste and
    /// by nothing else: the Edit menu's validation asks `fieldEnablesPaste(for:)`, which
    /// reads nothing.
    ///
    /// Asks what kinds the pasteboard has and never reads a picture, which can be large and
    /// is read only once the chat says it can take one. The one thing it can read is the
    /// text, and only where it was copied with a picture and a URL
    /// (`textIsOnlyTheAddress(on:)`) or with rich text that can hold pictures
    /// (`ReplyFieldPastePolicy.pictureMarks`).
    static func pasteAction(for pasteboard: NSPasteboard) -> ReplyFieldPastePolicy.Action {
        let carries = carriedKinds(on: pasteboard)
        return ReplyFieldPastePolicy.action(
            carriesFiles: carries.files,
            carriesText: carries.text,
            carriesImage: carries.image,
            carriesRichTextWithAttachments: pasteboard.availableType(from: [.rtfd]) != nil,
            textIsOnlyTheCopiedAddress: textIsOnlyTheAddress(on: pasteboard),
            pictureMarksInText: ReplyFieldPastePolicy.pictureMarks(in: pasteboard.string(forType: .string))
        )
    }

    /// Whether the field enables Paste for `pasteboard` by its own rule
    /// (`ReplyFieldPastePolicy.fieldEnablesPaste`): files, or a picture copied with no text.
    ///
    /// Decided from the kinds the pasteboard says it has, with nothing on it read. This is
    /// asked each time the Edit menu is validated, which is not a paste: the text and the
    /// URL are a paste's to read (`pasteAction(for:)`).
    static func fieldEnablesPaste(for pasteboard: NSPasteboard) -> Bool {
        let carries = carriedKinds(on: pasteboard)
        return ReplyFieldPastePolicy.fieldEnablesPaste(
            carriesFiles: carries.files,
            carriesText: carries.text,
            carriesImage: carries.image
        )
    }

    /// The kinds of thing `pasteboard` says it has. Its types are asked about and nothing on
    /// it is read, so this costs the same whatever was copied.
    private static func carriedKinds(on pasteboard: NSPasteboard) -> (files: Bool, text: Bool, image: Bool) {
        (
            files: MacDraftFileDropView.carriesFiles(pasteboard),
            text: pasteboard.availableType(from: [.string]) != nil,
            image: pasteboard.availableType(from: pastedImageTypes) != nil
        )
    }

    /// Whether the text on `pasteboard` is only the address of the picture beside it
    /// (`ReplyFieldPastePolicy.textIsOnlyTheAddress`).
    ///
    /// The text is read only from a pasteboard that says it carries a URL (`public.url`),
    /// which cells copied from a spreadsheet do not: their text, which can be long, is still
    /// never read here.
    private static func textIsOnlyTheAddress(on pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.availableType(from: [.URL]) != nil else { return false }
        return ReplyFieldPastePolicy.textIsOnlyTheAddress(
            text: pasteboard.string(forType: .string),
            address: pasteboard.string(forType: .URL)
        )
    }

    /// Paste is enabled for a copied image too, and for nothing while the window has a
    /// sheet attached. A text view enables it only for what it can read itself, and this
    /// one reads no images (`importsGraphics` is off), so with only an image copied the
    /// command, and Command-V with it, never reached `paste(_:)`.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if disablesPaste(item) { return false }
        return enablesPasteItself(item) ? true : super.validateUserInterfaceItem(item)
    }

    /// Whether `item` is a paste command asked about while the field's window has a sheet
    /// attached, where the field takes no paste (`ReplyFieldPastePolicy.fieldTakesPaste`).
    /// Asked before anything else of the command, and it reads nothing off the pasteboard.
    func disablesPaste(_ item: NSValidatedUserInterfaceItem) -> Bool {
        Self.isPasteCommand(item)
            && !ReplyFieldPastePolicy.fieldTakesPaste(windowHasSheet: window?.attachedSheet != nil)
    }

    /// Whether `item` is a paste command this field enables by its own rule: a copied file
    /// or image to attach. False for every other command, and for a paste of text, which
    /// are the text view's to answer. Apart from the override so a test can ask it: the text
    /// view's answer is read from the pasteboard the user copies to.
    ///
    /// It reads nothing off the pasteboard (`fieldEnablesPaste(for:)`), and must not come to
    /// ask `pasteAction(for:)`, which can read the text: this runs whenever the Edit menu is
    /// validated, with no paste asked for. A picture copied with text of any kind is left to
    /// the text view here, which enables Paste for the text beside it.
    func enablesPasteItself(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let isPaste = Self.isPasteCommand(item)
        return isPaste && isEditable && Self.fieldEnablesPaste(for: pasteboardForPaste())
    }

    private static func isPasteCommand(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:))
    }

    /// Writes pasted pictures to files of the app's own and hands them to the chat, which
    /// removes the files once they are imported. Returns whether the chat took them; where
    /// it did not, nothing is left behind.
    ///
    /// - Parameter pictures: Reads the pictures off the pasteboard. Called only once the
    ///   chat has said it can take them, so a refusal costs nothing: the read can be tens of
    ///   megabytes, and a TIFF is written again.
    private func attachPastedPictures(_ pictures: () -> [PastedImageEncoder.Attachable]) -> Bool {
        guard let chatDropView, chatDropView.takesPaste else { return false }
        let pictures = pictures()
        guard !pictures.isEmpty else { return false }
        var files: [PastedImageFile] = []
        for picture in pictures {
            guard let file = try? PastedImageFile.write(
                picture.data,
                fileExtension: picture.fileExtension,
                in: pastedImageDirectory()
            ) else {
                // All of what was copied, or none of it.
                PastedImageFile.remove(files)
                return false
            }
            files.append(file)
        }
        guard chatDropView.receivePastedImageFiles(files) else {
            PastedImageFile.remove(files)
            return false
        }
        return true
    }

    /// The chat's drop view behind this field, which takes pasted files as it takes dropped
    /// ones. Nil where the field has no chat behind it.
    ///
    /// Looked for under the middle of the part of the field that is on screen
    /// (`visibleRect`), not of its `bounds`. The view is its scroll view's document, as tall
    /// as its text, and the field shows a few lines of it: the middle of a long draft can be
    /// outside the window, where there is no chat, and every paste of a file or an image
    /// into such a draft was refused.
    private var chatDropView: MacDraftFileDropView? {
        let onScreen = visibleRect
        return MacDraftFileDropView.dropView(
            in: window,
            at: convert(NSPoint(x: onScreen.midX, y: onScreen.midY), to: nil)
        )
    }

    /// The forms a copied image is written to its file in as it came, in the order they are
    /// asked for, each with the extension of that file. The import takes either as an image
    /// (`DocumentAttachmentImporter`).
    private static let imageTypesWrittenAsTheyCame: [(type: NSPasteboard.PasteboardType, fileExtension: String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg")
    ]

    /// Every kind that makes a pasteboard one that carries an image. TIFF is the last one
    /// asked for (`image(on:)`), and the only one an app that copies an `NSImage` writes.
    private static let pastedImageTypes = imageTypesWrittenAsTheyCame.map(\.type) + [.tiff]

    /// The image on a pasteboard, in a form the draft's import takes as an image, with the
    /// extension of the file it is written to. Nil where it has none that can be used: a
    /// TIFF that cannot be read is no image.
    ///
    /// - PNG or JPEG, as it came.
    /// - Otherwise the picture's own file, where the pasteboard has it as rich text holding
    ///   that one file (`MacPastedRichText.solePicture`). Copy Image in a web view writes a
    ///   TIFF and, in RTFD, the file the page served (measured 2026-11-14). Taken from
    ///   there, a photograph is the page's JPEG and nothing is encoded. Written again from
    ///   the TIFF, as it was at first, it was a PNG several times the size, made on the main
    ///   thread (review of PR 422, 2026-11-14).
    /// - Otherwise the TIFF, written again as PNG or JPEG (`PastedImageEncoder.reencoded`):
    ///   the import does not take a `.tiff` as an image.
    static func image(on pasteboard: NSPasteboard) -> PastedImageEncoder.Attachable? {
        for (type, fileExtension) in imageTypesWrittenAsTheyCame {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return PastedImageEncoder.Attachable(data: data, fileExtension: fileExtension)
            }
        }
        if pasteboard.availableType(from: [.rtfd]) != nil,
           let picture = MacPastedRichText.solePicture(on: pasteboard) {
            return picture
        }
        guard let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty else { return nil }
        return PastedImageEncoder.reencoded(from: tiff)
    }

    // MARK: - Dragged files

    private let fileDropForwarder = MacFileDropForwarder()

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropForwarder.draggingEntered(sender, in: window) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropForwarder.draggingUpdated(sender) ?? super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // A file drag never reached the text view's own `draggingEntered`, so it is not told
        // of the exit either.
        if !fileDropForwarder.draggingExited() {
            super.draggingExited(sender)
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropForwarder.prepareForDragOperation(sender) ?? super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropForwarder.performDragOperation(sender) ?? super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if !fileDropForwarder.concludeDragOperation() {
            super.concludeDragOperation(sender)
        }
    }
}
#endif
