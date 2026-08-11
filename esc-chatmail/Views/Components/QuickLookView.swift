import SwiftUI
import QuickLook
import CoreData

struct QuickLookPresentation: Identifiable {
    let id = UUID()
    let previewItems: [AttachmentPreviewItem]
    let selectedIndex: Int

    init?(attachments: [Attachment], selectedAttachment: Attachment) {
        let previewItems = attachments.compactMap { attachment in
            AttachmentPreviewItem(attachment: attachment)
        }
        guard let selectedIndex = previewItems.firstIndex(where: {
            $0.attachment == selectedAttachment
        }) else {
            return nil
        }

        self.previewItems = previewItems
        self.selectedIndex = selectedIndex
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let presentation: QuickLookPresentation
    @Environment(\.dismiss) private var dismiss

    static func clampedPreviewIndex(_ index: Int, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return min(max(index, 0), itemCount - 1)
    }
    
    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.currentPreviewItemIndex = Self.clampedPreviewIndex(
            presentation.selectedIndex,
            itemCount: context.coordinator.previewItems.count
        )
        
        let navController = UINavigationController(rootViewController: controller)
        return navController
    }
    
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        // The presentation and its data source are an immutable snapshot.
        // QLPreviewController owns subsequent paging without SwiftUI resetting it.
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let parent: QuickLookView
        let previewItems: [AttachmentPreviewItem]
        
        init(_ parent: QuickLookView) {
            self.parent = parent
            self.previewItems = parent.presentation.previewItems
            super.init()
        }
        
        // MARK: - QLPreviewControllerDataSource
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return previewItems.count
        }
        
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return previewItems[index]
        }
        
        // MARK: - QLPreviewControllerDelegate
        
        func previewController(_ controller: QLPreviewController, didUpdateContentsOf previewItem: QLPreviewItem) {
            // Handle updates if needed
        }
        
        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            parent.dismiss()
        }
    }
}

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
