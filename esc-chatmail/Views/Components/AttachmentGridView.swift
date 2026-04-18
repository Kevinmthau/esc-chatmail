import SwiftUI
import CoreData
import QuickLook

struct AttachmentGridView: View {
    let attachments: [ChatMessageAttachmentModel]
    @EnvironmentObject private var deps: Dependencies
    @Environment(\.managedObjectContext) private var viewContext
    @State private var selectedAttachment: Attachment?
    @State private var showFullScreen = false
    @State private var currentIndex = 0

    private var resolvedAttachments: [Attachment] {
        attachments.compactMap { attachment in
            if let registered = viewContext.registeredObject(for: attachment.objectID) as? Attachment,
               !registered.isDeleted {
                return registered
            }

            guard let resolved = try? viewContext.existingObject(with: attachment.objectID) as? Attachment,
                  !resolved.isDeleted else {
                return nil
            }

            return resolved
        }
    }

    var body: some View {
        Group {
            if resolvedAttachments.count == 1, let attachment = resolvedAttachments.first {
                SingleAttachmentView(
                    attachment: attachment,
                    downloader: deps.attachmentDownloader,
                    onTap: {
                        selectedAttachment = attachment
                        currentIndex = 0
                        showFullScreen = true
                    }
                )
            } else if resolvedAttachments.count > 1 {
                AttachmentGrid(
                    attachments: resolvedAttachments,
                    downloader: deps.attachmentDownloader,
                    onTap: { attachment in
                        if let index = resolvedAttachments.firstIndex(of: attachment) {
                            currentIndex = index
                        }
                        selectedAttachment = attachment
                        showFullScreen = true
                    }
                )
            } else if !attachments.isEmpty {
                AttachmentIndicator(count: attachments.count)
            }
        }
        .sheet(isPresented: $showFullScreen) {
            QuickLookView(
                attachments: resolvedAttachments,
                currentIndex: $currentIndex
            )
        }
    }
}
