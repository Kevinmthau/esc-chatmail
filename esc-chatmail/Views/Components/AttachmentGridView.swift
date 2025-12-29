import SwiftUI
import CoreData
import QuickLook

struct AttachmentGridView: View {
    let attachments: [Attachment]
    @StateObject private var downloader = AttachmentDownloader.shared
    @State private var selectedAttachment: Attachment?
    @State private var showFullScreen = false
    @State private var currentIndex = 0

    var body: some View {
        Group {
            if attachments.count == 1, let attachment = attachments.first {
                SingleAttachmentView(
                    attachment: attachment,
                    downloader: downloader,
                    onTap: {
                        selectedAttachment = attachment
                        currentIndex = 0
                        showFullScreen = true
                    }
                )
            } else if attachments.count > 1 {
                AttachmentGrid(
                    attachments: attachments,
                    downloader: downloader,
                    onTap: { attachment in
                        if let index = attachments.firstIndex(of: attachment) {
                            currentIndex = index
                        }
                        selectedAttachment = attachment
                        showFullScreen = true
                    }
                )
            }
        }
        .sheet(isPresented: $showFullScreen) {
            QuickLookView(
                attachments: attachments,
                currentIndex: $currentIndex
            )
        }
    }
}
