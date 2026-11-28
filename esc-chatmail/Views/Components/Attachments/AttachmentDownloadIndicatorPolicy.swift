import Foundation

/// What an attachment's view shows of its transfer: one decision for the status icon
/// (`AttachmentStatusIcon`), the document card and the video card, which each made it apart.
enum AttachmentDownloadIndicatorPolicy {
    enum Indicator: Equatable {
        /// A spinner: an attachment the user added is being sent.
        case uploading
        /// An attachment the user added could not be sent; nothing to tap.
        case uploadFailed
        /// A received attachment's download failed; a Retry.
        case downloadFailed
        /// A received attachment's download was refused, or stopped, for want of space
        /// (`AttachmentDownloader.isRefusedForSpace`): "Not enough storage" with a Retry, which
        /// asks the free-space floor again. Its row is left as it was, `queued` or `failed`.
        case refusedForSpace
        /// A spinner: a download in flight.
        case downloading
        /// Not downloaded yet (the cards' cloud icon; the status icon shows nothing).
        case notDownloaded
        case none
    }

    /// A `local_inline_` row is a part of a received message, downloaded like any other, never
    /// sent: until 2026-11-28 the views read every `local_` ID as the user's own, so a queued
    /// inline part showed the sending spinner for as long as it stayed queued, and a failed one
    /// showed no Retry (architecture review 2026-11, attachments-storage-disk#5's review).
    static func indicator(
        state: Attachment.State,
        attachmentId: String?,
        isReady: Bool,
        isDownloading: Bool,
        isRefusedForSpace: Bool
    ) -> Indicator {
        let isUserAdded = attachmentId?.hasPrefix("local_") == true
            && attachmentId?.hasPrefix("local_inline_") != true
        if state == .uploading || (state == .queued && isUserAdded) {
            return .uploading
        }
        // Only while the row has no file: a sibling's recovery can store a refused part's file
        // after the refusal, and a badge over a ready image would be stale.
        if isRefusedForSpace, !isUserAdded, !isReady {
            return .refusedForSpace
        }
        if state == .failed {
            return isUserAdded ? .uploadFailed : .downloadFailed
        }
        if isDownloading {
            return .downloading
        }
        if !isReady, !isUserAdded {
            return .notDownloaded
        }
        return .none
    }
}
