import SwiftUI
import CoreData
import QuickLook

struct AttachmentGridView: View {
    let attachments: [ChatMessageAttachmentModel]
    @EnvironmentObject private var deps: Dependencies
    @Environment(\.managedObjectContext) private var viewContext
    @State private var quickLookPresentation: QuickLookPresentation?

    private func resolveAttachments() -> [Attachment] {
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
        let resolvedAttachments = resolveAttachments()

        Group {
            if resolvedAttachments.count == 1, let attachment = resolvedAttachments.first {
                SingleAttachmentView(
                    attachment: attachment,
                    downloader: deps.attachmentDownloader,
                    onTap: {
                        presentQuickLook(
                            for: attachment,
                            in: resolvedAttachments
                        )
                    }
                )
            } else if resolvedAttachments.count > 1 {
                AttachmentGrid(
                    attachments: resolvedAttachments,
                    downloader: deps.attachmentDownloader,
                    onTap: { attachment in
                        presentQuickLook(
                            for: attachment,
                            in: resolvedAttachments
                        )
                    }
                )
            } else if !attachments.isEmpty {
                AttachmentIndicator(count: attachments.count)
            }
        }
        .sheet(item: $quickLookPresentation) { presentation in
            QuickLookView(presentation: presentation)
        }
    }

    private func presentQuickLook(
        for attachment: Attachment,
        in resolvedAttachments: [Attachment]
    ) {
        quickLookPresentation = QuickLookPresentation(
            attachments: resolvedAttachments,
            selectedAttachment: attachment
        )
    }
}
