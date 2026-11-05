import Foundation
@testable import esc_chatmail

extension HTMLSaveResult {
    /// For persister tests that must not write message bodies to disk: reports the body as saved,
    /// at a path nothing reads. It replaces the old `{ _, _ in nil }` writer. Since body writes
    /// are classified (`MessageBodyWriteFailure`), nil would now mean a failed write and fail
    /// every message that has HTML.
    static func savedWithoutWriting(messageId: String) -> HTMLSaveResult {
        .saved(
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("unwritten-\(messageId).html")
        )
    }

    /// A write the volume refused because it is full, as `String.write(to:atomically:encoding:)`
    /// reports it: `NSFileWriteOutOfSpaceError` over POSIX `ENOSPC`.
    static var outOfSpace: HTMLSaveResult {
        .writeFailed(NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]
        ))
    }

    /// A write that failed for a reason other than space.
    static var ioFailure: HTMLSaveResult {
        .writeFailed(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError))
    }
}
