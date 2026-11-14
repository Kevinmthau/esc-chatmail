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

    /// A copied file is attached to the reply, and so is a copied image where nothing else
    /// was copied with it (`ReplyFieldPastePolicy`). Left to the text view, a copied file is
    /// pasted as its path (measured on this field, 2026-11-12) and a copied image as nothing.
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
            guard let image = Self.imageData(on: pasteboard), attachPastedImage(image) else {
                refusePaste()
                return true
            }
            return true
        }
    }

    /// What Paste would do with `pasteboard` (`ReplyFieldPastePolicy`). Asks what kinds the
    /// pasteboard has and reads none of them: this is asked each time the Edit menu is
    /// validated, and a copied image can be large.
    static func pasteAction(for pasteboard: NSPasteboard) -> ReplyFieldPastePolicy.Action {
        ReplyFieldPastePolicy.action(
            carriesFiles: MacDraftFileDropView.carriesFiles(pasteboard),
            carriesText: pasteboard.availableType(from: [.string]) != nil,
            carriesImage: pasteboard.availableType(from: pastedImageTypes.map(\.type)) != nil
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
    func enablesPasteItself(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let isPaste = item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:))
        return isPaste && isEditable && Self.pasteAction(for: pasteboardForPaste()) != .pasteAsText
    }

    /// Writes the image to a file of the app's own and hands it to the chat, which removes
    /// the file once it is imported. Returns whether the chat took it.
    private func attachPastedImage(_ image: (data: Data, fileExtension: String)) -> Bool {
        // Asked before the file is written, so a refusal leaves nothing behind.
        guard let chatDropView, chatDropView.acceptsPastedImage,
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
    private var chatDropView: MacDraftFileDropView? {
        MacDraftFileDropView.dropView(in: window, at: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil))
    }

    /// The image on a pasteboard, in the first of these forms it has, with the extension of
    /// the file it is written to. The import re-encodes it either way
    /// (`DraftAttachmentImport.prepareImage`).
    private static let pastedImageTypes: [(type: NSPasteboard.PasteboardType, fileExtension: String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (.tiff, "tiff")
    ]

    static func imageData(on pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        for (type, fileExtension) in pastedImageTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return (data, fileExtension)
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
