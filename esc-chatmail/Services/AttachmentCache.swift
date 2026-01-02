import UIKit
import Combine

class AttachmentCache {
    static let shared = AttachmentCache()

    private let thumbnailCache = NSCache<NSString, UIImage>()
    private let fullImageCache = NSCache<NSString, UIImage>()
    private let dataCache = NSCache<NSString, NSData>()
    private let loadingQueue = DispatchQueue(label: "com.esc.attachment.cache", attributes: .concurrent)
    private let requestManager = InFlightRequestManager<String, UIImage>()
    
    private init() {
        setupCacheLimits()
        observeMemoryWarnings()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupCacheLimits() {
        // Thumbnail cache: ~50MB (assuming ~100KB per thumbnail)
        thumbnailCache.countLimit = 500
        thumbnailCache.totalCostLimit = 50 * 1024 * 1024
        
        // Full image cache: ~100MB (for viewing)
        fullImageCache.countLimit = 20
        fullImageCache.totalCostLimit = 100 * 1024 * 1024
        
        // Data cache: ~25MB (for quick access to raw data)
        dataCache.countLimit = 50
        dataCache.totalCostLimit = 25 * 1024 * 1024
    }
    
    private func observeMemoryWarnings() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    @objc private func handleMemoryWarning() {
        clearCache(level: .aggressive)
    }
    
    enum CacheClearLevel {
        case light      // Clear full images only
        case moderate   // Clear full images and data
        case aggressive // Clear everything
    }
    
    func clearCache(level: CacheClearLevel = .moderate) {
        switch level {
        case .light:
            fullImageCache.removeAllObjects()
        case .moderate:
            fullImageCache.removeAllObjects()
            dataCache.removeAllObjects()
        case .aggressive:
            fullImageCache.removeAllObjects()
            dataCache.removeAllObjects()
            thumbnailCache.removeAllObjects()
            Task {
                await requestManager.clearFailedKeys()
            }
        }
    }
    
    // MARK: - Thumbnail Loading

    func loadThumbnail(for attachmentId: String, from path: String?) async -> UIImage? {
        let cacheKey = "thumb_\(attachmentId)"

        // Check memory cache
        if let cached = thumbnailCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        // Use request manager for deduplication
        let result = await requestManager.deduplicated(key: cacheKey) {
            // Load from disk
            guard let path = path,
                  let data = AttachmentPaths.loadData(from: path) else {
                return nil
            }

            // Decode image
            return UIImage(data: data)
        }

        // Cache the result outside the @Sendable closure
        if let image = result {
            let cost = image.jpegData(compressionQuality: 0.8)?.count ?? 0
            thumbnailCache.setObject(image, forKey: cacheKey as NSString, cost: cost)
        }

        return result
    }
    
    // MARK: - Downsampled Image Loading
    
    func loadDownsampledImage(
        for attachmentId: String,
        from path: String?,
        targetSize: CGSize,
        contentMode: UIView.ContentMode = .scaleAspectFill
    ) async -> UIImage? {
        let cacheKey = "downsampled_\(attachmentId)_\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
        
        // Check memory cache
        if let cached = fullImageCache.object(forKey: cacheKey) {
            return cached
        }
        
        // Load and downsample
        guard let path = path,
              let url = AttachmentPaths.fullURL(for: path) else {
            return nil
        }
        
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let image = self?.downsampleImage(at: url, to: targetSize, contentMode: contentMode) else {
                return nil
            }
            
            // Cache the downsampled image
            let cost = Int(targetSize.width * targetSize.height * 4) // Approximate memory cost
            self?.fullImageCache.setObject(image, forKey: cacheKey, cost: cost)
            
            return image
        }.value
    }
    
    private func downsampleImage(
        at url: URL,
        to targetSize: CGSize,
        contentMode: UIView.ContentMode
    ) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions) else {
            return nil
        }
        
        let maxDimensionInPixels = max(targetSize.width, targetSize.height) * UIScreen.main.scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
        ] as CFDictionary
        
        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else {
            return nil
        }
        
        return UIImage(cgImage: downsampledImage)
    }
    
    // MARK: - Full Image Loading
    
    func loadFullImage(for attachmentId: String, from path: String?) async -> UIImage? {
        let cacheKey = "full_\(attachmentId)" as NSString
        
        // Check memory cache
        if let cached = fullImageCache.object(forKey: cacheKey) {
            return cached
        }
        
        // Load from disk with size limit
        guard let path = path,
              let url = AttachmentPaths.fullURL(for: path) else {
            return nil
        }
        
        return await Task.detached(priority: .userInitiated) { [weak self] in
            // Use downsampling for very large images
            let maxDimension: CGFloat = 4096
            let targetSize = CGSize(width: maxDimension, height: maxDimension)
            
            guard let image = self?.loadImageWithSizeLimit(at: url, maxSize: targetSize) else {
                return nil
            }
            
            // Cache with estimated cost
            let cost = Int(image.size.width * image.size.height * 4 * image.scale * image.scale)
            self?.fullImageCache.setObject(image, forKey: cacheKey, cost: cost)
            
            return image
        }.value
    }
    
    private func loadImageWithSizeLimit(at url: URL, maxSize: CGSize) -> UIImage? {
        // First, get image dimensions without loading the full image
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        
        // If image is small enough, load it directly
        if width <= maxSize.width && height <= maxSize.height {
            return UIImage(contentsOfFile: url.path)
        }
        
        // Otherwise, downsample it
        return downsampleImage(at: url, to: maxSize, contentMode: .scaleAspectFit)
    }
    
    // MARK: - Data Cache
    
    func cacheData(_ data: Data, for key: String) {
        dataCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }
    
    func getCachedData(for key: String) -> Data? {
        return dataCache.object(forKey: key as NSString) as Data?
    }
    
    // MARK: - Preloading
    
    func preloadThumbnails(for attachmentIds: [(id: String, path: String?)]) {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for (id, path) in attachmentIds.prefix(10) { // Limit concurrent preloads
                    group.addTask { [weak self] in
                        _ = await self?.loadThumbnail(for: id, from: path)
                    }
                }
            }
        }
    }
}

