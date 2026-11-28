import Foundation

/// How a write of an attachment's bytes to its stored path ended (`AttachmentPaths.writeData`).
///
/// A full disk is told apart from every other failure because the two are answered
/// differently: a write that found no room leaves the row as it was (`queued`, the resting
/// state of a received attachment), so the next showing asks again once there is room, and
/// nothing marks it failed or retries it; any other failure marks the row failed, as before.
/// Until 2026-11-28 `saveData` answered a bare Bool and the cause was lost in a log line
/// (architecture review 2026-11, attachments-storage-disk#5).
enum AttachmentWriteResult: Equatable, Sendable {
    /// The bytes are on disk, whole, with their backup mark.
    case saved
    /// The volume had no room (`StorageErrorClassifier.isOutOfSpace`: ENOSPC, EDQUOT, Cocoa's
    /// out-of-space write error, anywhere in the error's chain).
    case outOfSpace
    /// Any other failure: no path, a permission, a directory in the way.
    case failed

    /// The write's error as one of the two failures.
    init(classifying error: Error) {
        self = StorageErrorClassifier.isOutOfSpace(error) ? .outOfSpace : .failed
    }
}
