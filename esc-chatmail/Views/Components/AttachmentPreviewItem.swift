import Foundation
import QuickLook

class AttachmentPreviewItem: NSObject, QLPreviewItem {
    let attachment: Attachment
    let previewItemURL: URL?

    init?(attachment: Attachment) {
        guard let url = Self.fileURL(for: attachment) else {
            return nil
        }
        self.attachment = attachment
        self.previewItemURL = url
        super.init()
    }

    static func fileURL(for attachment: Attachment) -> URL? {
        // Remote paths must prove the composite message/attachment identity;
        // an ID-only legacy path may point at a sibling message's bytes.
        let readablePaths = [
            attachment.readableLocalURLValue,
            attachment.readablePreviewURLValue
        ].compactMap { $0 }
        return readablePaths.lazy
            .compactMap({ AttachmentPaths.fullURL(for: $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    var previewItemTitle: String? {
        return attachment.filename
    }
}
