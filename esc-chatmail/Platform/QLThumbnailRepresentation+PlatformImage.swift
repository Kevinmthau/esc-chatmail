import QuickLookThumbnailing

extension QLThumbnailRepresentation {
    /// The thumbnail as the app's image type: `uiImage` on iOS, `nsImage` on the Mac.
    var platformImage: PlatformImage {
        #if canImport(UIKit)
        uiImage
        #else
        nsImage
        #endif
    }
}
