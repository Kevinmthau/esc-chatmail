#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// What a drag of an attachment out of a Mac chat carries (`MacAttachmentDragSourceView`): a
/// promise of the attachment's file under the name a save would offer.
///
/// A promise, not the file's URL, because of the name. The file on disk is named for its
/// storage identity (`AttachmentPaths`), and the Finder copies a dragged file under the name
/// it has. With a promise the Finder says where the file goes and this writes it there, named
/// by `AttachmentExportPolicy.filename`. No second copy of the attachment is made in the
/// app's container to carry the name, which a sign-out would then have to find and delete.
///
/// The cost is that an app taking only file URLs, not promises, does not take the drag.
///
/// It is its own delegate: a provider holds its delegate weakly, and the pasteboard keeps the
/// provider until the promise is kept.
final class MacAttachmentFilePromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    /// Set once, in `init(item:)`, before the provider is given to a drag.
    private var promisedItem: AttachmentExportItem?

    /// The copy runs here, off the main thread: an attachment can be 25 MB and the
    /// destination another volume.
    private static let writeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MacAttachmentFilePromiseProvider.write"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    convenience init(item: AttachmentExportItem) {
        self.init()
        promisedItem = item
        fileType = Self.fileType(forFilename: item.filename)
        delegate = self
    }

    /// The type the promise is announced as, from the name's extension; plain data where the
    /// extension says nothing.
    static func fileType(forFilename filename: String) -> String {
        let pathExtension = AttachmentExportPolicy.splitExtension(of: filename).pathExtension
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else {
            return UTType.data.identifier
        }
        return type.identifier
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        promisedItem?.filename ?? AttachmentExportPolicy.fallbackBaseName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let promisedItem else {
            completionHandler(
                AttachmentFileExport.ExportError.sourceMissing(filename: AttachmentExportPolicy.fallbackBaseName)
            )
            return
        }
        do {
            try AttachmentFileExport.writePromise(promisedItem, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.writeQueue
    }
}
#endif
