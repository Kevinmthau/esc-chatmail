import SwiftUI

struct AttachmentStatusOverlay: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader

    var body: some View {
        VStack {
            HStack {
                Spacer()
                AttachmentStatusIcon(
                    attachment: attachment,
                    downloader: downloader
                )
                .padding(8)
            }
            Spacer()
        }
    }
}
