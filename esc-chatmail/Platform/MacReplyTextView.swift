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

    /// A copied file is attached to the reply, and so is a copied image where no text was
    /// copied with it but its own address (`ReplyFieldPastePolicy`). Left to the text view, a
    /// copied file is pasted as its path (measured on this field, 2026-11-12) and a copied
    /// image as nothing. An image copied in a web view would be pasted as its address, going
    /// by what WebKit's source writes with it; that was not measured.
    override func paste(_ sender: Any?) {
        if !pasteAttachments() {
            super.paste(sender)
        }
    }

    /// Paste and Match Style is the same command for a field with one style.
    override func pasteAsPlainText(_ sender: Any?) {
        if !pasteAttachments() {
            super.pasteAsPlainText(sender)
        }
    }

    /// Attaches what was copied, where it is files or an image. Returns false for anything
    /// else, which is then the text view's to paste.
    ///
    /// A paste the chat cannot take now (a send owns the draft, an import is running) is
    /// refused with a beep and is still answered here: the text view must never be given a
    /// copied file to paste, or it types the path.
    func pasteAttachments() -> Bool {
        let pasteboard = pasteboardForPaste()
        switch Self.pasteAction(for: pasteboard) {
        case .pasteAsText:
            return false
        case .attachFiles:
            let files = MacDraftFileDropView.fileURLs(on: pasteboard)
            if chatDropView?.receivePastedFiles(files) != true {
                refusePaste()
            }
            return true
        case .attachImage:
            if !attachPastedImage(from: pasteboard) {
                refusePaste()
            }
            return true
        }
    }

    /// What Paste would do with `pasteboard` (`ReplyFieldPastePolicy`). Asked by a paste and
    /// by nothing else: the Edit menu's validation asks `fieldEnablesPaste(for:)`, which
    /// reads nothing.
    ///
    /// Asks what kinds the pasteboard has and never reads an image, which can be large and
    /// is read only once the chat says it can take one. The one thing it can read is the
    /// text (`textIsOnlyTheAddress(on:)`), and only where a picture and text were copied
    /// together.
    static func pasteAction(for pasteboard: NSPasteboard) -> ReplyFieldPastePolicy.Action {
        let carries = carriedKinds(on: pasteboard)
        return ReplyFieldPastePolicy.action(
            carriesFiles: carries.files,
            carriesText: carries.text,
            carriesImage: carries.image,
            textIsOnlyTheCopiedAddress: textIsOnlyTheAddress(on: pasteboard)
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
            image: pasteboard.availableType(from: pastedImageTypes.map(\.type)) != nil
        )
    }

    /// Whether the text on `pasteboard` is only the address of the picture beside it, as
    /// Copy Image in a web view leaves it (`ReplyFieldPastePolicy.textIsOnlyTheAddress`).
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

    /// Paste is enabled for a copied image too. A text view enables it only for what it can
    /// read itself, and this one reads no images (`importsGraphics` is off), so with only an
    /// image copied the command, and Command-V with it, never reached `paste(_:)`.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        enablesPasteItself(item) ? true : super.validateUserInterfaceItem(item)
    }

    /// Whether `item` is a paste command this field enables by its own rule: a copied file
    /// or image to attach. False for every other command, and for a paste of text, which
    /// are the text view's to answer. Apart from the override so a test can ask it: the text
    /// view's answer is read from the pasteboard the user copies to.
    ///
    /// It reads nothing off the pasteboard (`fieldEnablesPaste(for:)`), and must not come to
    /// ask `pasteAction(for:)`, which can read the text: this runs whenever the Edit menu is
    /// validated, with no paste asked for. A picture copied with its address is left to the
    /// text view here, which enables Paste for the text beside it.
    func enablesPasteItself(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let isPaste = item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:))
        return isPaste && isEditable && Self.fieldEnablesPaste(for: pasteboardForPaste())
    }

    /// Writes the image on `pasteboard` to a file of the app's own and hands it to the chat,
    /// which removes the file once it is imported. Returns whether the chat took it.
    private func attachPastedImage(from pasteboard: NSPasteboard) -> Bool {
        // Asked before the image is read, so a refusal costs nothing and leaves nothing
        // behind: the read can be tens of megabytes, and a TIFF is re-encoded.
        guard let chatDropView, chatDropView.acceptsPastedImage,
              let image = Self.imageData(on: pasteboard),
              let file = try? PastedImageFile.write(
                  image.data,
                  fileExtension: image.fileExtension,
                  in: pastedImageDirectory()
              ) else {
            return false
        }
        guard chatDropView.receivePastedImageFile(file) else {
            PastedImageFile.remove([file])
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

    /// The forms a copied image is taken in, in the order they are asked for, each with the
    /// extension of the file it is written to. PNG and JPEG are written as they came, and the
    /// import takes either as an image (`DocumentAttachmentImporter`). TIFF is written as PNG
    /// (`PastedImagePNGEncoder`): the import does not take a `.tiff` as an image.
    private static let pastedImageTypes: [(type: NSPasteboard.PasteboardType, fileExtension: String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (.tiff, "png")
    ]

    /// The image on a pasteboard, in the first of `pastedImageTypes` it has that can be
    /// used, with the extension of the file it is written to. Nil where it has none: a TIFF
    /// that cannot be read is no image.
    static func imageData(on pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        for (type, fileExtension) in pastedImageTypes {
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            guard type == .tiff else { return (data, fileExtension) }
            if let png = PastedImagePNGEncoder.pngData(from: data) {
                return (png, fileExtension)
            }
        }
        return nil
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
