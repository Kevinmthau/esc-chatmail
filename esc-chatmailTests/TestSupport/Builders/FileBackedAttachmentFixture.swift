import CoreData
import Foundation
@testable import esc_chatmail

/// An attachment for the suites that save, drag or open an attachment's file: its file, where
/// it has one, is `<its id>.<ext>` in a directory of the test's own, never in the app's
/// attachment folder.
enum FileBackedAttachmentFixture {
    /// - Parameters:
    ///   - bytes: The file's contents. Nil for an attachment whose file is not on disk.
    ///   - directory: Where the file is written, and where the test resolves `localURL`.
    static func make(
        _ filename: String,
        state: Attachment.State = .downloaded,
        bytes: String? = "bytes",
        in context: NSManagedObjectContext,
        directory: URL
    ) throws -> Attachment {
        let id = "local_\(UUID().uuidString)"
        let attachment = AttachmentBuilder().withId(id).withFilename(filename).build(in: context)
        attachment.state = state
        let stored = "\(id).\((filename as NSString).pathExtension)"
        attachment.localURL = stored
        if let bytes {
            try Data(bytes.utf8).write(to: directory.appendingPathComponent(stored))
        }
        return attachment
    }
}
