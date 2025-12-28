import UIKit
import CoreGraphics
import PDFKit

struct ImageProcessor {
    static let maxThumbnailDimension: CGFloat = 1600
    static let maxFullSizeDimension: CGFloat = 4096
    static let jpegCompressionQuality: CGFloat = 0.85
    
    static func processImage(data: Data, maxDimension: CGFloat = maxFullSizeDimension) -> (processed: Data?, size: CGSize?) {
        // Validate data is not empty
        guard !data.isEmpty else {
            Log.debug("ImageProcessor: Empty data provided", category: .attachment)
            return (nil, nil)
        }

        // Try to create image from data
        guard let image = UIImage(data: data) else {
            Log.debug("ImageProcessor: Failed to create UIImage from data of size \(data.count)", category: .attachment)
            return (nil, nil)
        }

        // Validate image dimensions
        let size = image.size
        guard size.width > 0 && size.height > 0 else {
            Log.debug("ImageProcessor: Invalid image dimensions \(size)", category: .attachment)
            return (nil, nil)
        }

        let scale = min(maxDimension / max(size.width, size.height), 1.0)

        if scale >= 1.0 {
            return (data, size)
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        // Use newer rendering API if available
        if #available(iOS 10.0, *) {
            let renderer = UIGraphicsImageRenderer(size: newSize)
            let jpegData = renderer.jpegData(withCompressionQuality: jpegCompressionQuality) { context in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
            return (jpegData, newSize)
        } else {
            // Fallback for older iOS versions
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            defer { UIGraphicsEndImageContext() }

            image.draw(in: CGRect(origin: .zero, size: newSize))

            guard let resizedImage = UIGraphicsGetImageFromCurrentImageContext(),
                  let jpegData = resizedImage.jpegData(compressionQuality: jpegCompressionQuality) else {
                return (nil, nil)
            }

            return (jpegData, newSize)
        }
    }
    
    static func generateThumbnail(from data: Data, mimeType: String) -> Data? {
        if mimeType.starts(with: "image/") {
            let (thumbnailData, _) = processImage(data: data, maxDimension: maxThumbnailDimension)
            return thumbnailData
        } else if mimeType == "application/pdf" {
            return generatePDFThumbnail(from: data)
        }
        return nil
    }
    
    static func generatePDFThumbnail(from data: Data) -> Data? {
        guard let document = PDFDocument(data: data),
              let firstPage = document.page(at: 0) else {
            return nil
        }
        
        let pageRect = firstPage.bounds(for: .mediaBox)
        let scale = min(maxThumbnailDimension / max(pageRect.width, pageRect.height), 1.0)
        let thumbnailSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        UIGraphicsBeginImageContextWithOptions(thumbnailSize, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: thumbnailSize))
        
        context.translateBy(x: 0, y: thumbnailSize.height)
        context.scaleBy(x: scale, y: -scale)
        
        firstPage.draw(with: .mediaBox, to: context)
        
        guard let thumbnailImage = UIGraphicsGetImageFromCurrentImageContext(),
              let jpegData = thumbnailImage.jpegData(compressionQuality: jpegCompressionQuality) else {
            return nil
        }
        
        return jpegData
    }
    
    static func getPDFPageCount(from data: Data) -> Int? {
        guard let document = PDFDocument(data: data) else { return nil }
        return document.pageCount
    }
    
    static func getImageDimensions(from data: Data) -> CGSize? {
        guard let image = UIImage(data: data) else { return nil }
        return image.size
    }
}