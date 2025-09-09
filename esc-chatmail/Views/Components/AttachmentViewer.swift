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
                        Text((attachment.value(forKey: "filename") as? String) ?? "Attachment")
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
    
    var body: some View {
        GeometryReader { geometry in
            if let localURL = attachment.value(forKey: "localURL") as? String,
               let data = AttachmentPaths.loadData(from: localURL),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
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
            } else if let previewURL = attachment.value(forKey: "previewURL") as? String,
                      let previewData = AttachmentPaths.loadData(from: previewURL),
                      let uiImage = UIImage(data: previewData) {
                // Fallback to preview if original not available
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
        }
    }
}

struct PDFDetailView: View {
    let attachment: Attachment
    
    var body: some View {
        if let localURL = attachment.value(forKey: "localURL") as? String,
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
            
            Text((attachment.value(forKey: "filename") as? String) ?? "Attachment")
                .font(.headline)
                .foregroundColor(.white)
            
            Text((attachment.value(forKey: "mimeType") as? String) ?? "Unknown type")
                .font(.caption)
                .foregroundColor(.gray)
            
            if let byteSize = attachment.value(forKey: "byteSize") as? Int64, byteSize > 0 {
                Text(formatFileSize(byteSize))
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