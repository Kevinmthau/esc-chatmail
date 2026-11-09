import Foundation

/// Files an attachment import has written but not yet handed to an `Attachment`, deleted if the
/// import stops before it does. Shared by the photo import (`AttachmentPicker`) and the document
/// import (`DocumentAttachmentImporter`).
struct PickerPendingAttachmentWrite {
    var originalPath: String?
    var previewPath: String?
}
