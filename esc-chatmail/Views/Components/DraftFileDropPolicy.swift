import Foundation
import UniformTypeIdentifiers

/// What a chat does with files dragged onto it (the Mac; `MacDraftFileDropView`).
///
/// A drop adds the files to the reply's attachments through the import the Files picker uses
/// (`DocumentAttachmentImporter`), so it takes what that picker offers and waits where its
/// button waits.
enum DraftFileDropPolicy {
    enum Decision: Equatable {
        /// The drop is not taken, and the dragged files slide back to where they came from.
        case refuse
        /// The drop is taken: `fileURLs` are imported, and `unsupportedFilenames` are named in
        /// an alert. Either may be empty, not both.
        case accept(fileURLs: [URL], unsupportedFilenames: [String])
    }

    /// Whether the reply can take dropped files now. False where the picker's buttons are
    /// disabled, for the same two reasons, and for one of a drop's own:
    /// - A send owns the draft (`ChatReplyBarControlPolicy.allowsDraftMutation`).
    /// - Another import is running. The composer has one "processing" flag, which each import
    ///   turns off as it ends, so the first of two to finish would enable Send while the other
    ///   still had a placeholder in the draft.
    /// - An earlier drop is still waiting for the picker (`ChatComposerState.pendingFileDrop`).
    ///   The composer holds one, and a second would replace it: the first drop's files were
    ///   taken from the user and then never attached.
    static func acceptsFiles(
        allowsDraftMutation: Bool,
        isProcessingAttachments: Bool,
        hasPendingDrop: Bool
    ) -> Bool {
        allowsDraftMutation && !isProcessingAttachments && !hasPendingDrop
    }

    /// Whether the picker starts on the composer's pending drop now. It waits while another
    /// import runs, for `acceptsFiles`' reason, and starts when that one ends: a drop that
    /// was taken is always imported. The composer refuses a drop during an import, so the
    /// wait is for an import that began between the drop and the picker hearing of it.
    static func startsImport(hasPendingDrop: Bool, isProcessingAttachments: Bool) -> Bool {
        hasPendingDrop && !isProcessingAttachments
    }

    /// Whether a drag over the chat is one it would take, which is what gives the pointer its
    /// copy badge (`MacDraftFileDropView`). Asked on every move of a drag and again at the
    /// drop.
    ///
    /// - Parameters:
    ///   - windowHasSheet: The chat's window has a sheet attached. The chat is behind the
    ///     sheet then, and an alert about the drop would wait unseen behind it too, as a menu
    ///     command's would (`MailboxMenuPolicy`).
    ///   - carriesFiles: The drag holds files, not a link or a run of text.
    ///   - sourceAllowsCopy: Where the drag came from lets its files be copied.
    ///   - acceptsFiles: `acceptsFiles(allowsDraftMutation:isProcessingAttachments:hasPendingDrop:)`.
    static func takesDrag(
        windowHasSheet: Bool,
        carriesFiles: Bool,
        sourceAllowsCopy: Bool,
        acceptsFiles: Bool
    ) -> Bool {
        !windowHasSheet && carriesFiles && sourceAllowsCopy && acceptsFiles
    }

    static func decision(
        droppedURLs: [URL],
        allowsDraftMutation: Bool,
        isProcessingAttachments: Bool,
        hasPendingDrop: Bool
    ) -> Decision {
        let files = droppedURLs.filter(\.isFileURL)
        guard !files.isEmpty,
              acceptsFiles(
                  allowsDraftMutation: allowsDraftMutation,
                  isProcessingAttachments: isProcessingAttachments,
                  hasPendingDrop: hasPendingDrop
              ) else {
            return .refuse
        }
        // A drop of nothing but unsupported files is still taken: the alert that names them
        // says why nothing was added, where a refusal would say nothing.
        return .accept(
            fileURLs: files.filter(isSupported),
            unsupportedFilenames: files.filter { !isSupported($0) }.map(\.lastPathComponent)
        )
    }

    /// Whether the Files picker would have offered this file: an image or a PDF, judged by its
    /// name alone, as the import judges it. A folder has no such extension and is not taken.
    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return DocumentAttachmentImporter.allowedContentTypes.contains { type.conforms(to: $0) }
    }

    /// The alert's lines for the files a drop could not take, in the form the import reports
    /// its own failures (`DraftAttachmentImport.failureMessage`).
    static func failures(forUnsupportedFilenames filenames: [String]) -> [String] {
        filenames.map {
            DraftAttachmentImport.ImportError.unsupportedType(filename: $0).localizedDescription
        }
    }
}
