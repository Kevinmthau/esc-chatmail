import Foundation

/// What became of one message body write (`HTMLContentHandler.saveHTMLResult`).
///
/// A caller that only needs the file uses `saveHTML`, which folds both failures into nil. Sync
/// persistence must not: it maps each case to a different verdict (`MessageBodyWriteFailure`).
enum HTMLSaveResult {
    /// The body is on disk at this URL.
    case saved(URL)
    /// The account boundary was closed, or had moved to another generation, so nothing was
    /// written. This is account teardown, not a fault in the write.
    case boundaryClosed
    /// The write itself failed: a full volume, or any other file-system error.
    case writeFailed(Error)

    /// Where the body is on disk, or nil when it could not be written.
    var savedURL: URL? {
        guard case .saved(let url) = self else { return nil }
        return url
    }

    /// Why the body is not on disk, or nil when it is.
    var bodyWriteFailure: MessageBodyWriteFailure? {
        switch self {
        case .saved:
            return nil
        case .boundaryClosed:
            return .boundaryClosed
        case .writeFailed(let error):
            return StorageErrorClassifier.isOutOfSpace(error) ? .outOfSpace : .ioError
        }
    }
}
