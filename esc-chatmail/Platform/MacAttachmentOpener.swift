#if os(macOS)
import AppKit

/// Opens a message's attachment in the app the Mac has for its kind: Open, in an attachment's
/// menu (`MacAttachmentExportMenu`).
///
/// Four rules, each kept somewhere a test can reach:
/// - **Which kinds** (`AttachmentOpenPolicy`). The menu offers Open only for those, and this
///   asks again before it opens anything, so the rule holds whatever calls it.
/// - **What is opened** (`AttachmentOpenCopy`): a read-only copy under the attachment's own
///   name, never the app's stored file.
/// - **How.** `NSWorkspace` is behind a closure, as the save panels are behind theirs
///   (`MacAttachmentExporter`): a test must never launch another app.
/// - **Whose.** The copy is written into `Attachments`, which is account data, so it is made
///   as registered account work (`AttachmentAccountWorkRegistry`): sign-out closes that
///   registry and waits for the copy before it removes the directory, and an Open that the
///   sign-out overtook opens nothing.
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
    private let registry: AttachmentAccountWorkRegistry

    /// - Parameter registry: The account boundary the copy registers with. The tests give
    ///   one of their own: the shared one is the process's, and another suite may close it.
    init(
        makeCopy: @escaping CopyMaker = { try MacAttachmentOpener.makeCopyInAttachments($0) },
        openFile: @escaping FileOpener = { NSWorkspace.shared.open($0) },
        presentFailure: @escaping FailurePresenter = {
            MacAttachmentSavePanels.presentFailure(title: $0, message: $1)
        },
        registry: AttachmentAccountWorkRegistry = .shared
    ) {
        self.makeCopy = makeCopy
        self.openFile = openFile
        self.presentFailure = presentFailure
        self.registry = registry
    }

    /// Open: the attachment's file, copied, in the app for its kind.
    ///
    /// An Open that a sign-out overtakes ends without a word: the account is leaving, its
    /// files with it, and an alert about one of them over the sign-in screen would say
    /// nothing the user does not know. That is the one case where the entry does nothing.
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
        // The account this Open belongs to. Captured here, before the first suspension, and
        // asked again after the copy: a sign-out closes admission and a sign-in reopens it
        // under another generation, so a token that is still current means no account
        // transition began in between.
        guard let admission = registry.captureAdmissionToken() else { return }
        let makeCopy = makeCopy
        let outcome = CopyOutcome()
        // An attachment can be 25 MB, so the copy does not hold the main thread. Detached
        // through the registry, never a bare `Task.detached`: the registry is what sign-out
        // drains before it removes `Attachments` (`AuthSession`'s `cleanupDownloads`), and a
        // copy it does not know of could land in the directory while it is removed, or after.
        let operation = registry.startDetachedOperation(for: admission) { generation in
            guard generation.isActive else { return }
            let result: Result<URL, AttachmentOpenPolicy.Failure>
            do {
                result = .success(try makeCopy(item))
            } catch AttachmentFileExport.ExportError.sourceMissing {
                result = .failure(.sourceMissing(filename: item.filename))
            } catch AttachmentFileExport.ExportError.copyFailed(_, let reason) {
                result = .failure(.copyFailed(filename: item.filename, reason: reason))
            } catch {
                result = .failure(.copyFailed(filename: item.filename, reason: error.localizedDescription))
            }
            // A sign-out that began during the copy is waiting for this to end, and removes
            // what it wrote. Its result is nobody's.
            guard generation.isActive else { return }
            outcome.set(result)
        }
        guard let operation else { return }
        await operation.value
        guard let prepared = outcome.value, registry.captureAdmissionToken() == admission else {
            return
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

    /// What the copy's operation found, handed from that task to the Open that waits for it.
    /// Nil until the operation sets it, and for good when a sign-out overtook it.
    ///
    /// `@unchecked Sendable`: `stored` is read and written only under `lock`.
    private final class CopyOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<URL, AttachmentOpenPolicy.Failure>?

        func set(_ result: Result<URL, AttachmentOpenPolicy.Failure>) {
            lock.withLock { stored = result }
        }

        var value: Result<URL, AttachmentOpenPolicy.Failure>? {
            lock.withLock { stored }
        }
    }
}
#endif
