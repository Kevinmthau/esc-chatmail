import SwiftUI
import PDFKit
import QuickLook

struct AttachmentViewer: View {
    let attachments: [Attachment]
    @Binding var selectedAttachment: Attachment?
    @Binding var isPresented: Bool
    @State private var currentIndex: Int = 0
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let selectedAttachment = selectedAttachment,
                   let index = attachments.firstIndex(of: selectedAttachment) {
                    TabView(selection: $currentIndex) {
                        ForEach(Array(attachments.enumerated()), id: \.element) { index, attachment in
                            AttachmentDetailView(attachment: attachment)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(PageTabViewStyle())
                    .onAppear {
                        currentIndex = index
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        isPresented = false
                    }
                    .foregroundColor(.white)
                }
                
                ToolbarItem(placement: .principal) {
                    if let attachment = attachments[safe: currentIndex] {
                        Text(attachment.filename)
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    if attachments.count > 1 {
                        Text("\(currentIndex + 1) of \(attachments.count)")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct AttachmentDetailView: View {
    let attachment: Attachment
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        Group {
            if attachment.isImage {
                ImageDetailView(
                    attachment: attachment,
                    zoomScale: $zoomScale,
                    lastScale: $lastScale,
                    offset: $offset,
                    lastOffset: $lastOffset
                )
            } else if attachment.isPDF {
                PDFDetailView(attachment: attachment)
            } else {
                UnsupportedAttachmentView(attachment: attachment)
            }
        }
    }
}

struct ImageDetailView: View {
    let attachment: Attachment
    @Binding var zoomScale: CGFloat
    @Binding var lastScale: CGFloat
    @Binding var offset: CGSize
    @Binding var lastOffset: CGSize
    @State private var fullImage: UIImage?
    @State private var isLoadingImage = false
    private let cache = AttachmentCacheActor.shared
    
    var body: some View {
        GeometryReader { geometry in
            if let image = fullImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoomScale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / lastScale
                                lastScale = value
                                zoomScale = min(max(zoomScale * delta, 1), 4)
                            }
                            .onEnded { _ in
                                lastScale = 1.0
                                if zoomScale < 1.2 {
                                    withAnimation(.spring()) {
                                        zoomScale = 1.0
                                        offset = .zero
                                    }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                if zoomScale > 1.0 {
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            if zoomScale > 1.5 {
                                zoomScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                zoomScale = 2.0
                            }
                        }
                    }
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .onAppear {
                        loadFullImage()
                    }
            }
        }
    }
    
    private func loadFullImage() {
        guard fullImage == nil,
              !isLoadingImage,
              let attachmentId = attachment.id else { return }
        
        isLoadingImage = true
        Task {
            let localPath = attachment.localURL
            
            if let image = await cache.loadFullImage(for: attachmentId, from: localPath) {
                await MainActor.run {
                    self.fullImage = image
                    self.isLoadingImage = false
                }
            } else {
                // Fallback to preview if full image fails
                let previewPath = attachment.previewURL
                if let image = await cache.loadThumbnail(for: attachmentId, from: previewPath) {
                    await MainActor.run {
                        self.fullImage = image
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
}

struct PDFDetailView: View {
    let attachment: Attachment
    
    var body: some View {
        if let localURL = attachment.localURL,
           let data = AttachmentPaths.loadData(from: localURL) {
            PDFKitView(data: data)
                .edgesIgnoringSafeArea(.all)
        } else {
            VStack {
                Image(systemName: "doc.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.gray)
                Text("PDF not available")
                    .foregroundColor(.gray)
            }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        if let document = PDFDocument(data: data) {
            pdfView.document = document
        }
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {}
}

struct UnsupportedAttachmentView: View {
    let attachment: Attachment
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            
            Text(attachment.filename)
                .font(.headline)
                .foregroundColor(.white)
            
            Text(attachment.mimeType)
                .font(.caption)
                .foregroundColor(.gray)
            
            if attachment.byteSize > 0 {
                Text(formatFileSize(attachment.byteSize))
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}