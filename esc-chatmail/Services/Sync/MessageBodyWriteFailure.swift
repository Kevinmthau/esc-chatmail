import Foundation

/// Why sync persistence could not write a message's HTML body, which decides what becomes of the
/// message (`MessagePersister.dispositionAfterBodyWriteFailure`).
///
/// Before these were told apart, every failed write persisted the row with no body: a known
/// `.notRich` verdict that no backfill revisits, a bubble whose HTML recovery never opens, and
/// a cursor that advanced past it. On a full disk that left newsletters as stripped text for
/// good, even after space was freed (`enospc-bodyless-rows` in `docs/scalability-review.md`).
///
/// `MessagePersister.createNewMessage` throws it, before anything is inserted, and
/// `MessagePersister.persist` turns it into the message's verdict.
enum MessageBodyWriteFailure: LocalizedError, Sendable, Equatable {
    /// The account boundary closed under the write: teardown, which surfaces as cancellation.
    case boundaryClosed
    /// The volume is full (`StorageErrorClassifier.isOutOfSpace`). Says nothing about this
    /// message and fails every write after it, so the run aborts (`SyncResourceAbort`).
    case outOfSpace
    /// Any other write failure. Blocks this message only (`.failed`): the cursor holds and the
    /// next run's re-scan retries it.
    case ioError

    var errorDescription: String? {
        switch self {
        case .boundaryClosed:
            return "The message body was not written because the account was closing."
        case .outOfSpace:
            return "The message body could not be written because the device is out of space."
        case .ioError:
            return "The message body could not be written."
        }
    }
}
