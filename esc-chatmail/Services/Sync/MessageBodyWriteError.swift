import Foundation

/// Thrown by `MessagePersister.createNewMessage` when the body write failed, before anything was
/// inserted. `MessagePersister.persist` turns it into the message's verdict
/// (`dispositionAfterBodyWriteFailure`).
struct MessageBodyWriteError: Error {
    let failure: MessageBodyWriteFailure
}
