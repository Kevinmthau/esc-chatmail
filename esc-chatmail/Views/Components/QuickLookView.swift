import SwiftUI
import QuickLook
import CoreData

struct QuickLookView: UIViewControllerRepresentable {
    let attachments: [Attachment]
    @Binding var currentIndex: Int
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.currentPreviewItemIndex = currentIndex
        
        let navController = UINavigationController(rootViewController: controller)
        return navController
    }
    
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        if let qlController = uiViewController.viewControllers.first as? QLPreviewController {
            if qlController.currentPreviewItemIndex != currentIndex {
                qlController.currentPreviewItemIndex = currentIndex
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let parent: QuickLookView
        var previewItems: [QLPreviewItem] = []
        
        init(_ parent: QuickLookView) {
            self.parent = parent
            super.init()
            self.previewItems = parent.attachments.compactMap { attachment in
                AttachmentPreviewItem(attachment: attachment)
            }
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
        
        // Get the file URL from the attachment's local storage
        if let localURL = attachment.value(forKey: "localURL") as? String,
           let url = AttachmentPaths.fullURL(for: localURL) {
            // Ensure the file exists
            if FileManager.default.fileExists(atPath: url.path) {
                self._fileURL = url
            } else {
                // Try to load from preview if original doesn't exist
                if let previewURL = attachment.value(forKey: "previewURL") as? String,
                   let url = AttachmentPaths.fullURL(for: previewURL),
                   FileManager.default.fileExists(atPath: url.path) {
                    self._fileURL = url
                } else {
                    return nil
                }
            }
        } else {
            return nil
        }
    }
    
    var previewItemURL: URL? {
        return _fileURL
    }
    
    var previewItemTitle: String? {
        return attachment.value(forKey: "filename") as? String ?? "Attachment"
    }
}