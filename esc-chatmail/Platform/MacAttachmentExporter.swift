#if os(macOS)
import AppKit

/// Saves a message's attachments out of the Mac app: Save Attachment… and Save All
/// Attachments… in an attachment's menu (`MacAttachmentExportMenu`).
///
/// The user picks the place in a save panel, which in the sandbox is what gives the app leave
/// to write there (`ENABLE_USER_SELECTED_FILES` is `readwrite` for the Mac). The panels and the
/// alert are closures so the tests can stand in for them: none of the three can be shown in a
/// test host.
///
/// A panel is a sheet on the app's window, so while it is up the window takes no clicks and a
/// second save cannot be asked for. A sign-out that lands meanwhile deletes the files; the save
/// then reports that the attachment is no longer on this Mac and writes nothing.
@MainActor
final class MacAttachmentExporter {
    static let shared = MacAttachmentExporter()

    /// Asks where to save one file, offering `suggestedFilename`. Nil when the user cancels.
    typealias FileChooser = @MainActor (_ suggestedFilename: String) async -> URL?
    /// Asks for a folder to save `count` files into. Nil when the user cancels.
    typealias FolderChooser = @MainActor (_ count: Int) async -> URL?
    typealias FailurePresenter = @MainActor (_ title: String, _ message: String) -> Void

    private let chooseFile: FileChooser
    private let chooseFolder: FolderChooser
    private let presentFailure: FailurePresenter

    init(
        chooseFile: @escaping FileChooser = { await MacAttachmentSavePanels.chooseFile(suggestedFilename: $0) },
        chooseFolder: @escaping FolderChooser = { await MacAttachmentSavePanels.chooseFolder(count: $0) },
        presentFailure: @escaping FailurePresenter = {
            MacAttachmentSavePanels.presentFailure(title: $0, message: $1)
        }
    ) {
        self.chooseFile = chooseFile
        self.chooseFolder = chooseFolder
        self.presentFailure = presentFailure
    }

    /// Save Attachment…: one file, at the place and under the name the user gives it.
    ///
    /// - Parameters:
    ///   - item: Nil where the attachment has no file to save, which is said in the alert: a
    ///     menu entry that did nothing would not say why.
    ///   - displayFilename: The attachment's name for that alert.
    func save(_ item: AttachmentExportItem?, displayFilename: String) async {
        guard let item else {
            present([.sourceMissing(filename: displayFilename)])
            return
        }
        guard let destination = await chooseFile(item.filename) else { return }
        let failure = await Self.offMain { () -> AttachmentFileExport.ExportError? in
            do {
                try AttachmentFileExport.save(item, to: destination)
                return nil
            } catch let error as AttachmentFileExport.ExportError {
                return error
            } catch {
                return .copyFailed(filename: item.filename, reason: error.localizedDescription)
            }
        }
        if let failure {
            present([failure])
        }
    }

    /// Save All Attachments…: every file into one folder, each under its own name.
    ///
    /// - Parameters:
    ///   - missingFilenames: Attachments of the message that should have a file and have
    ///     none. They are listed in the alert after the others are saved.
    func saveAll(_ items: [AttachmentExportItem], missingFilenames: [String] = []) async {
        let missing = missingFilenames.map { AttachmentFileExport.ExportError.sourceMissing(filename: $0) }
        guard !items.isEmpty else {
            present(missing)
            return
        }
        guard let folder = await chooseFolder(items.count) else { return }
        let failures = await Self.offMain {
            AttachmentFileExport.saveAll(items, into: folder)
        }
        present(failures + missing)
    }

    private func present(_ failures: [AttachmentFileExport.ExportError]) {
        guard !failures.isEmpty else { return }
        presentFailure(
            AttachmentExportPolicy.failureTitle(failureCount: failures.count),
            AttachmentFileExport.failureMessage(for: failures)
        )
    }

    /// The copy can cross volumes and an attachment can be 25 MB, so it does not hold the main
    /// thread.
    private static func offMain<Result: Sendable>(
        _ work: @escaping @Sendable () -> Result
    ) async -> Result {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}
#endif
