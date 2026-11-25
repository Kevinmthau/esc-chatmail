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
                    showOverlay: attachments.count > 6 && attachment == attachments[5],
                    overlayCount: attachments.count - 5,
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
        // own to ask when it appears, so the grid asks for them when it appears.
        .task(id: overflowAttachmentIDs) {
            for attachment in attachments.dropFirst(Self.visibleCellCount) {
                guard !Task.isCancelled else { return }
                guard !attachment.isDeleted, attachment.managedObjectContext != nil else { continue }
                await downloader.downloadAttachmentIfNeeded(for: attachment)
            }
        }
    }

    static let visibleCellCount = 6

    private var overflowAttachmentIDs: [NSManagedObjectID] {
        attachments.dropFirst(Self.visibleCellCount).map(\.objectID)
    }
}
