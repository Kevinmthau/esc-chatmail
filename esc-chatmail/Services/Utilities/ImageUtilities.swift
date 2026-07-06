import Foundation
import UIKit

// MARK: - Base64 Image Decoding (Consolidated)

/// Centralized utilities for image decoding - eliminates duplicate code across views
enum ImageDecoder {
    /// Decodes a base64 data URL to UIImage. Thread-safe, can be called from any thread.
    static func decodeBase64DataURL(_ dataURL: String) -> UIImage? {
        guard dataURL.hasPrefix("data:image"),
              let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }
        let base64String = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else { return nil }
        return UIImage(data: data)
    }

    /// Decodes image data on a background thread
    static func decodeAsync(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)
        }.value
    }

    /// Decodes a base64 data URL on a background thread
    static func decodeBase64Async(_ dataURL: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            decodeBase64DataURL(dataURL)
        }.value
    }
}
