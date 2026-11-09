#if canImport(UIKit)
import UIKit

/// Scene lookups for the full-email WebView pool on iOS. The Mac has no window scenes: its pool
/// window and warm width come from `OffscreenWebViewHost` and `FullEmailReaderWarmWidthSource`.
enum FullEmailWebViewMetrics {
    @MainActor
    static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}
#endif
