import SwiftUI
import CoreData

struct AttachmentGrid: View {
    let attachments: [Attachment]
    @ObservedObject var downloader: AttachmentDownloader
    var imagePresentations: [NSManagedObjectID: InlineImagePresentationPolicy] = [:]
    let onTap: (Attachment) -> Void

    var columns: [GridItem] {
        let count = min(attachments.count, 3)
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: count == 1 ? 1 : 2)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(attachments.prefix(Self.visibleCellCount)) { attachment in
                AttachmentGridItem(
                    attachment: attachment,
                    downloader: downloader,
                    showOverlay: attachments.count > Self.visibleCellCount
                        && attachment == attachments[Self.visibleCellCount - 1],
                    overlayCount: attachments.count - (Self.visibleCellCount - 1),
                    imagePresentation: imagePresentations[attachment.objectID] ?? .standard,
                    onTap: { onTap(attachment) }
                )
                // On the cell, not the grid: the drag and the menu are the clicked attachment's.
                .macAttachmentDragSource(
                    attachment: attachment,
                    onClick: { onTap(attachment) }
                )
                .macAttachmentExportMenu(
                    attachment: attachment,
                    shownAttachments: attachments,
                    onQuickLook: { onTap(attachment) }
                )
            }
        }
        .cornerRadius(14)
        // The grid draws six cells and folds the rest into the sixth's "+N", which opens them
        // in Quick Look (and on the Mac, Save All saves them). Attachments download only when
        // asked for (`AttachmentDownloader`), and those past the sixth have no view of their
        // own to ask when it appears, so the grid asks for them when it appears. Not a
        // `.task`, which a lazy list cancels as the grid scrolls away: like the cells' own
        // downloads, these run to their end.
        .onAppear {
            let overflow = attachments.dropFirst(Self.visibleCellCount).filter {
                !$0.isDeleted && $0.managedObjectContext != nil &&
                    !InlineImagePresentationPolicy.requiresExplicitRetry(attachment: $0, isFromMe: $0.message?.isFromMe ?? false)
            }
            guard !overflow.isEmpty else { return }
            Task {
                for attachment in overflow where !attachment.isDeleted {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
        }
    }

    static let visibleCellCount = 6

}
