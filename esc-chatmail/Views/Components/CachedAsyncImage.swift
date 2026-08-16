import SwiftUI

struct CachedAsyncImageSource: Equatable {
    let imageData: Data?
    let imageURL: String?

    init(imageData: Data?, imageURL: String?) {
        self.imageData = imageData
        self.imageURL = imageURL?.isEmpty == false ? imageURL : nil
    }
}

@MainActor
final class CachedAsyncImageLoader: ObservableObject {
    typealias DataDecoder = @Sendable (Data) async -> UIImage?
    typealias URLLoader = @Sendable (String) async -> UIImage?

    @Published private(set) var image: UIImage?
    @Published private(set) var loadedSource: CachedAsyncImageSource?
    @Published private(set) var loadingSource: CachedAsyncImageSource?

    private var currentSource: CachedAsyncImageSource?
    private let decodeImageData: DataDecoder
    private let loadImageURL: URLLoader

    init(
        decodeImageData: @escaping DataDecoder = { data in
            await ImageDecoder.decodeAsync(data)
        },
        loadImageURL: @escaping URLLoader = { urlString in
            await EnhancedImageCache.shared.loadImage(from: urlString)
        }
    ) {
        self.decodeImageData = decodeImageData
        self.loadImageURL = loadImageURL
    }

    func load(for source: CachedAsyncImageSource) async {
        guard loadedSource != source else { return }

        currentSource = source
        image = nil
        loadedSource = nil
        loadingSource = nil

        if let data = source.imageData {
            let decodedImage = await decodeImageData(data)
            guard canPublish(source) else { return }
            if let decodedImage {
                image = decodedImage
                loadedSource = source
                return
            }
        }

        guard let urlString = source.imageURL else { return }
        loadingSource = source

        let loadedImage = await loadImageURL(urlString)
        guard canPublish(source) else { return }

        loadingSource = nil
        if let loadedImage {
            image = loadedImage
            loadedSource = source
        }
    }

    private func canPublish(_ source: CachedAsyncImageSource) -> Bool {
        !Task.isCancelled && currentSource == source
    }
}

/// A cached async image loader that supports both Data and URL sources
struct CachedAsyncImage: View {
    let imageData: Data?
    let imageURL: String?
    let size: CGFloat
    let showsProgressWhileLoading: Bool
    let imageBorderColor: Color?
    let imageBorderWidth: CGFloat
    let placeholder: AnyView

    @StateObject private var loader = CachedAsyncImageLoader()

    private var source: CachedAsyncImageSource {
        CachedAsyncImageSource(imageData: imageData, imageURL: imageURL)
    }

    init(
        imageData: Data? = nil,
        imageURL: String? = nil,
        size: CGFloat,
        showsProgressWhileLoading: Bool = true,
        imageBorderColor: Color? = nil,
        imageBorderWidth: CGFloat = 0,
        @ViewBuilder placeholder: () -> some View
    ) {
        self.imageData = imageData
        self.imageURL = imageURL
        self.size = size
        self.showsProgressWhileLoading = showsProgressWhileLoading
        self.imageBorderColor = imageBorderColor
        self.imageBorderWidth = imageBorderWidth
        self.placeholder = AnyView(placeholder())
    }

    var body: some View {
        Group {
            if loader.loadedSource == source, let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay {
                        if let imageBorderColor, imageBorderWidth > 0 {
                            Circle()
                                .stroke(imageBorderColor, lineWidth: imageBorderWidth)
                        }
                    }
            } else if loader.loadingSource == source && showsProgressWhileLoading {
                ProgressView()
                    .frame(width: size, height: size)
            } else {
                placeholder
            }
        }
        .task(id: source) {
            await loader.load(for: source)
        }
    }
}
