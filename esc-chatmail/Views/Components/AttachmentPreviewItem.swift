import Foundation
import QuickLook

class AttachmentPreviewItem: NSObject, QLPreviewItem {
    let attachment: Attachment
    private var _fileURL: URL?
    
    init?(attachment: Attachment) {
        self.attachment = attachment
        super.init()

        guard let url = Self.fileURL(for: attachment) else {
            return nil
        }
        self._fileURL = url
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
    
    var previewItemURL: URL? {
        return _fileURL
    }
    
    var previewItemTitle: String? {
        return attachment.filename
    }
}
