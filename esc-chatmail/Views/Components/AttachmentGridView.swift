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

struct SingleAttachmentView: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void
    
    var body: some View {
        Group {
            if attachment.isImage {
                ImageAttachmentBubble(
                    attachment: attachment,
                    downloader: downloader,
                    onTap: {
                        // Only allow tap if downloaded or uploaded
                        if attachment.isReady {
                            onTap()
                        }
                    }
                )
            } else if attachment.isPDF {
                PDFAttachmentCard(
                    attachment: attachment,
                    downloader: downloader,
                    onTap: {
                        // Only allow tap if downloaded or uploaded
                        if attachment.isReady {
                            onTap()
                        }
                    }
                )
            }
        }
    }
}

struct ImageAttachmentBubble: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void
    @State private var thumbnailImage: UIImage?
    @State private var isLoadingImage = false
    
    private let maxWidth = UIScreen.main.bounds.width * 0.65
    private let cache = AttachmentCache.shared
    
    var isDownloading: Bool {
        if let attachmentId = attachment.id {
            return downloader.activeDownloads.contains(attachmentId)
        }
        return false
    }
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: maxWidth)
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                        )
                } else if isLoadingImage {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 200, height: 150)
                        .overlay(
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        )
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 200, height: 150)
                        .overlay(
                            VStack {
                                Image(systemName: "photo")
                                    .font(.system(size: 30))
                                    .foregroundColor(.gray)
                                Text(attachment.filename)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        )
                }
                
                // Status overlay
                AttachmentStatusOverlay(
                    attachment: attachment,
                    downloader: downloader
                )
            }
        }
        .buttonStyle(PlainButtonStyle())
        .opacity([.downloaded, .uploaded, .failed].contains(attachment.state) ? 1.0 : 0.7)
        .disabled(!attachment.isReady)
        .onAppear {
            loadThumbnail()
            if attachment.state == .queued {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
        }
        .onDisappear {
            // Cancel loading if view disappears
            isLoadingImage = false
        }
    }
    
    private func loadThumbnail() {
        guard thumbnailImage == nil,
              !isLoadingImage,
              let attachmentId = attachment.id else { return }
        
        isLoadingImage = true
        Task {
            let previewPath = attachment.previewURL
            if let image = await cache.loadThumbnail(for: attachmentId, from: previewPath) {
                await MainActor.run {
                    self.thumbnailImage = image
                    self.isLoadingImage = false
                }
            } else {
                await MainActor.run {
                    self.isLoadingImage = false
                }
            }
        }
    }
}

struct PDFAttachmentCard: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void
    @State private var thumbnailImage: UIImage?
    @State private var isLoadingImage = false
    private let cache = AttachmentCache.shared
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Thumbnail
                if let previewURL = attachment.previewURL,
                   let previewData = AttachmentPaths.loadData(from: previewURL),
                   let uiImage = UIImage(data: previewData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 80)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 60, height: 80)
                        .overlay(
                            Image(systemName: "doc.fill")
                                .foregroundColor(.gray)
                        )
                }
                
                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.filename)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Text("PDF")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if attachment.pageCount > 0 {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(attachment.pageCount) pages")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if attachment.byteSize > 0 {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(formatFileSize(attachment.byteSize))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Status
                AttachmentStatusIcon(
                    attachment: attachment,
                    downloader: downloader
                )
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            loadThumbnail()
            if attachment.state == .queued {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
        }
    }
    
    private func loadThumbnail() {
        guard thumbnailImage == nil,
              !isLoadingImage,
              let attachmentId = attachment.id else { return }
        
        isLoadingImage = true
        Task {
            let previewPath = attachment.previewURL
            if let image = await cache.loadThumbnail(for: attachmentId, from: previewPath) {
                await MainActor.run {
                    self.thumbnailImage = image
                    self.isLoadingImage = false
                }
            } else {
                await MainActor.run {
                    self.isLoadingImage = false
                }
            }
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct AttachmentGrid: View {
    let attachments: [Attachment]
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: (Attachment) -> Void
    
    var columns: [GridItem] {
        let count = min(attachments.count, 3)
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: count == 1 ? 1 : 2)
    }
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(attachments.prefix(6)) { attachment in
                AttachmentGridItem(
                    attachment: attachment,
                    downloader: downloader,
                    showOverlay: attachments.count > 6 && attachment == attachments[5],
                    overlayCount: attachments.count - 5,
                    onTap: { onTap(attachment) }
                )
            }
        }
        .cornerRadius(14)
    }
}

struct AttachmentGridItem: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let showOverlay: Bool
    let overlayCount: Int
    let onTap: () -> Void
    @State private var thumbnailImage: UIImage?
    @State private var isLoadingImage = false
    private let cache = AttachmentCache.shared
    
    var body: some View {
        Button(action: {
            // Only allow tap if downloaded or uploaded
            if attachment.isReady {
                onTap()
            }
        }) {
            GeometryReader { geometry in
                ZStack {
                    if let image = thumbnailImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .overlay(
                                Group {
                                    if isLoadingImage {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle())
                                            .scaleEffect(0.6)
                                    } else {
                                        Image(systemName: attachment.isPDF ? "doc.fill" : "photo")
                                            .foregroundColor(.gray)
                                    }
                                }
                            )
                    }
                    
                    if showOverlay {
                        Rectangle()
                            .fill(Color.black.opacity(0.6))
                            .overlay(
                                Text("+\(overlayCount)")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            )
                    }
                    
                    AttachmentStatusOverlay(
                        attachment: attachment,
                        downloader: downloader
                    )
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            loadThumbnail()
            if attachment.state == .queued {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
        }
    }
    
    private func loadThumbnail() {
        guard thumbnailImage == nil,
              !isLoadingImage,
              let attachmentId = attachment.id else { return }
        
        isLoadingImage = true
        Task {
            let previewPath = attachment.previewURL
            let targetSize = CGSize(width: 200, height: 200) // Grid items are small
            
            // Try to load downsampled for grid view
            if let localPath = attachment.localURL,
               attachment.isImage {
                if let image = await cache.loadDownsampledImage(
                    for: attachmentId,
                    from: localPath,
                    targetSize: targetSize
                ) {
                    await MainActor.run {
                        self.thumbnailImage = image
                        self.isLoadingImage = false
                    }
                    return
                }
            }
            
            // Fall back to preview
            if let image = await cache.loadThumbnail(for: attachmentId, from: previewPath) {
                await MainActor.run {
                    self.thumbnailImage = image
                    self.isLoadingImage = false
                }
            } else {
                await MainActor.run {
                    self.isLoadingImage = false
                }
            }
        }
    }
}

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

struct AttachmentStatusIcon: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader

    private var isLocalAttachment: Bool {
        (attachment.id)?.starts(with: "local_") == true
    }

    var body: some View {
        Group {
            if attachment.state == .uploading ||
               (attachment.state == .queued && isLocalAttachment) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                    .frame(width: 20, height: 20)
            } else if attachment.state == .failed {
                if isLocalAttachment {
                    // Upload failure - show error icon with "Send failed" tooltip
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 20))
                } else {
                    // Download failure - allow retry
                    Button(action: {
                        Task {
                            await downloader.retryFailedDownload(for: attachment)
                        }
                    }) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 20))
                    }
                }
            } else if let attachmentId = attachment.id,
                      downloader.activeDownloads.contains(attachmentId) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                    .frame(width: 20, height: 20)
            }
        }
    }
}