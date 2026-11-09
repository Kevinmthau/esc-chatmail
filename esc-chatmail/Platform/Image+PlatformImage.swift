import SwiftUI

extension Image {
    /// SwiftUI's view of a `PlatformImage`: `Image(uiImage:)` on iOS, `Image(nsImage:)` on the Mac.
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
