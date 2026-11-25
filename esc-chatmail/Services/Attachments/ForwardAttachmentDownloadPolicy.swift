import Foundation

/// Which of a message's attachments a forward downloads before it copies them.
///
/// Attachments download only when something asks for them (`AttachmentDownloader`), so a
/// forward can be the first to ask: a message whose files the chat has not drawn yet, an
/// inline part its bubble hides, a legacy row that has to be fetched again. Without this a
/// forward of such a message dropped its regular files (`skippedForwardAttachmentCount`)
/// and refused outright over an inline one ("still being prepared").
///
/// The condition is `AttachmentDownloader.downloadAttachmentIfNeeded`'s own, less what
/// cannot be downloaded: a `local_` original (what the user attached) exists only on this
/// device. A synthesized `local_inline_` body part can, from its message.
enum ForwardAttachmentDownloadPolicy {
    static func needsDownload(_ attachment: Attachment) -> Bool {
        if attachment.isLocalAttachment, attachment.id?.hasPrefix("local_inline_") != true {
            return false
        }
        switch attachment.state {
        case .queued, .failed:
            return true
        case .downloaded, .uploaded:
            return attachment.needsRedownload
        case .uploading:
            return false
        }
    }
}
