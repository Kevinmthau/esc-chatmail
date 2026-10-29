import SwiftUI
import CoreData

struct AttachmentGridView: View {
    let attachments: [ChatMessageAttachmentModel]
    var inlineImagePresentations: [NSManagedObjectID: InlineImagePresentationPolicy] = [:]
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
        // Collapsed queued images still download through MessageBubble's
        // independent trigger and never reserve a grid cell or overflow count.
        let resolvedAttachments = resolveAttachments().filter {
            inlineImagePresentations[$0.objectID] != .collapsed
        }

        Group {
            if resolvedAttachments.count == 1, let attachment = resolvedAttachments.first {
                SingleAttachmentView(
                    attachment: attachment,
                    downloader: deps.attachmentDownloader,
                    imagePresentation: inlineImagePresentations[attachment.objectID] ?? .standard,
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
                    imagePresentations: inlineImagePresentations,
                    onTap: { attachment in
                        presentQuickLook(
                            for: attachment,
                            in: resolvedAttachments
                        )
                    }
                )
            } else if attachments.contains(where: { inlineImagePresentations[$0.objectID] != .collapsed }) {
                AttachmentIndicator(count: attachments.filter { inlineImagePresentations[$0.objectID] != .collapsed }.count)
            }
        }
        // Quick Look presents itself as a UIKit modal rather than in a SwiftUI
        // sheet: inside a sheet it had no Done button and a drag on the document
        // only scrolled it (see `QuickLookPreviewController`). Its dismissal clears
        // the state, and so does a presentation that never appeared, or the task
        // would present it unprompted when the view reappears. Neither may clear a
        // newer tap's presentation (`QuickLookPresentationPolicy`).
        .task(id: quickLookPresentation?.id) {
            guard let presentation = quickLookPresentation else { return }
            let outcome = await QuickLookPreviewController.present(presentation) {
                guard QuickLookPresentationPolicy.shouldClearOnDismiss(
                    of: presentation.id,
                    current: quickLookPresentation?.id
                ) else { return }
                quickLookPresentation = nil
            }
            if outcome == .noPresenter {
                Log.error("Quick Look found no presenter for attachment preview", category: .ui)
            }
            guard QuickLookPresentationPolicy.shouldClearAfterPresentAttempt(
                presentation.id,
                outcome: outcome,
                current: quickLookPresentation?.id
            ) else { return }
            quickLookPresentation = nil
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
