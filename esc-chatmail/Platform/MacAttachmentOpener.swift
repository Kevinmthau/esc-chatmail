#if os(macOS)
import AppKit

/// Opens a message's attachment in the app the Mac has for its kind: Open, in an attachment's
/// menu (`MacAttachmentExportMenu`).
///
/// Three rules, each kept somewhere a test can reach:
/// - **Which kinds** (`AttachmentOpenPolicy`). The menu offers Open only for those, and this
///   asks again before it opens anything, so the rule holds whatever calls it.
/// - **What is opened** (`AttachmentOpenCopy`): a read-only copy under the attachment's own
///   name, never the app's stored file.
/// - **How.** `NSWorkspace` is behind a closure, as the save panels are behind theirs
///   (`MacAttachmentExporter`): a test must never launch another app.
///
/// HONEST SCOPE: nothing has been opened. That the sandbox lets `NSWorkspace` hand another
/// app a file from this app's container, and what that app then shows for a read-only file,
/// have not been seen (`docs/mac-app-plan.md`, "Files").
@MainActor
final class MacAttachmentOpener {
    static let shared = MacAttachmentOpener()

    /// Makes the copy to open and says where it is.
    typealias CopyMaker = @Sendable (AttachmentExportItem) throws -> URL
    /// Asks the system to open the file. False when it opened nothing.
    typealias FileOpener = @MainActor (URL) async -> Bool
    typealias FailurePresenter = @MainActor (_ title: String, _ message: String) -> Void

    private let makeCopy: CopyMaker
    private let openFile: FileOpener
    private let presentFailure: FailurePresenter

    init(
        makeCopy: @escaping CopyMaker = { try MacAttachmentOpener.makeCopyInAttachments($0) },
        openFile: @escaping FileOpener = { NSWorkspace.shared.open($0) },
        presentFailure: @escaping FailurePresenter = {
            MacAttachmentSavePanels.presentFailure(title: $0, message: $1)
        }
    ) {
        self.makeCopy = makeCopy
        self.openFile = openFile
        self.presentFailure = presentFailure
    }

    /// Open: the attachment's file, copied, in the app for its kind.
    ///
    /// - Parameters:
    ///   - item: Nil where the attachment has no file to open, which is said in the alert: a
    ///     menu entry that did nothing would not say why.
    ///   - displayFilename: The attachment's name for that alert.
    func open(_ item: AttachmentExportItem?, displayFilename: String) async {
        guard let item else {
            present(.sourceMissing(filename: displayFilename))
            return
        }
        // Asked here as well as by the menu: nothing reaches `NSWorkspace` but through this.
        guard AttachmentOpenPolicy.isOpenable(filename: item.filename) else {
            present(.kindNotOpened(filename: item.filename))
            return
        }
        let makeCopy = makeCopy
        let prepared = await Self.offMain { () -> Result<URL, AttachmentOpenPolicy.Failure> in
            do {
                return .success(try makeCopy(item))
            } catch AttachmentFileExport.ExportError.sourceMissing {
                return .failure(.sourceMissing(filename: item.filename))
            } catch AttachmentFileExport.ExportError.copyFailed(_, let reason) {
                return .failure(.copyFailed(filename: item.filename, reason: reason))
            } catch {
                return .failure(.copyFailed(filename: item.filename, reason: error.localizedDescription))
            }
        }
        switch prepared {
        case .failure(let failure):
            present(failure)
        case .success(let copy):
            if await !openFile(copy) {
                present(.notOpened(filename: item.filename))
            }
        }
    }

    /// The copy, in `Attachments/Opened` (`AttachmentOpenCopy`).
    nonisolated static func makeCopyInAttachments(_ item: AttachmentExportItem) throws -> URL {
        guard let directory = AttachmentOpenCopy.defaultDirectory() else {
            throw AttachmentFileExport.ExportError.copyFailed(
                filename: item.filename,
                reason: "The folder for opened attachments could not be found."
            )
        }
        return try AttachmentOpenCopy.prepare(item, in: directory)
    }

    private func present(_ failure: AttachmentOpenPolicy.Failure) {
        presentFailure(AttachmentOpenPolicy.failureTitle, AttachmentOpenPolicy.failureMessage(for: failure))
    }

    /// An attachment can be 25 MB, so the copy does not hold the main thread.
    private static func offMain<Value: Sendable>(
        _ work: @escaping @Sendable () -> Value
    ) async -> Value {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}
#endif
