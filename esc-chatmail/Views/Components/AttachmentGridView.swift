import SwiftUI
import CoreData
import QuickLook

struct AttachmentGridView: View {
    let attachments: [Attachment]
    @EnvironmentObject private var deps: Dependencies
    @State private var selectedAttachment: Attachment?
    @State private var showFullScreen = false
    @State private var currentIndex = 0

    var body: some View {
        Group {
            if attachments.count == 1, let attachment = attachments.first {
                SingleAttachmentView(
                    attachment: attachment,
                    downloader: deps.attachmentDownloader,
                    onTap: {
                        selectedAttachment = attachment
                        currentIndex = 0
                        showFullScreen = true
                    }
                )
            } else if attachments.count > 1 {
                AttachmentGrid(
                    attachments: attachments,
                    downloader: deps.attachmentDownloader,
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
