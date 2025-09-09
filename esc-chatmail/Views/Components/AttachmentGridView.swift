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
                        // Only allow tap if downloaded
                        if (attachment.value(forKey: "stateRaw") as? String) == "downloaded" {
                            onTap()
                        }
                    }
                )
            } else if attachment.isPDF {
                PDFAttachmentCard(
                    attachment: attachment,
                    downloader: downloader,
                    onTap: {
                        // Only allow tap if downloaded
                        if (attachment.value(forKey: "stateRaw") as? String) == "downloaded" {
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
    
    private let maxWidth = UIScreen.main.bounds.width * 0.65
    
    var isDownloading: Bool {
        if let attachmentId = attachment.value(forKey: "id") as? String {
            return downloader.activeDownloads.contains(attachmentId)
        }
        return false
    }
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                if let previewURL = attachment.value(forKey: "previewURL") as? String,
                   let previewData = AttachmentPaths.loadData(from: previewURL),
                   let uiImage = UIImage(data: previewData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: maxWidth)
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
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
                                Text((attachment.value(forKey: "filename") as? String) ?? "Image")
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
        .opacity((attachment.value(forKey: "stateRaw") as? String) == "downloaded" ? 1.0 : 0.7)
        .disabled((attachment.value(forKey: "stateRaw") as? String) != "downloaded")
        .onAppear {
            if (attachment.value(forKey: "stateRaw") as? String) == "queued" {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
                }
            }
        }
    }
}

struct PDFAttachmentCard: View {
    let attachment: Attachment
    @ObservedObject var downloader: AttachmentDownloader
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Thumbnail
                if let previewURL = attachment.value(forKey: "previewURL") as? String,
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
                    Text((attachment.value(forKey: "filename") as? String) ?? "Document.pdf")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Text("PDF")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        if let pageCount = attachment.value(forKey: "pageCount") as? Int16, pageCount > 0 {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(pageCount) pages")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        if let byteSize = attachment.value(forKey: "byteSize") as? Int64, byteSize > 0 {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(formatFileSize(byteSize))
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
            if (attachment.value(forKey: "stateRaw") as? String) == "queued" {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
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
    
    var body: some View {
        Button(action: {
            // Only allow tap if downloaded
            if (attachment.value(forKey: "stateRaw") as? String) == "downloaded" {
                onTap()
            }
        }) {
            GeometryReader { geometry in
                ZStack {
                    if let previewURL = attachment.value(forKey: "previewURL") as? String,
                       let previewData = AttachmentPaths.loadData(from: previewURL),
                       let uiImage = UIImage(data: previewData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.1))
                            .overlay(
                                Image(systemName: attachment.isPDF ? "doc.fill" : "photo")
                                    .foregroundColor(.gray)
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
            if (attachment.value(forKey: "stateRaw") as? String) == "queued" {
                Task {
                    await downloader.downloadAttachmentIfNeeded(for: attachment)
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
    
    var body: some View {
        Group {
            if (attachment.value(forKey: "stateRaw") as? String) == "uploading" ||
               ((attachment.value(forKey: "stateRaw") as? String) == "queued" && (attachment.value(forKey: "id") as? String)?.starts(with: "local_") == true) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                    .frame(width: 20, height: 20)
            } else if (attachment.value(forKey: "stateRaw") as? String) == "failed" {
                Button(action: {
                    Task {
                        await downloader.retryFailedDownload(for: attachment)
                    }
                }) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 20))
                }
            } else if let attachmentId = attachment.value(forKey: "id") as? String,
                      downloader.activeDownloads.contains(attachmentId) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)
                    .frame(width: 20, height: 20)
            }
        }
    }
}