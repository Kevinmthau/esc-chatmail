#if os(iOS)
import UIKit
#endif

/// Whether the app can read its data-protected files right now.
@MainActor
enum ProtectedDataAvailability {
    /// `UIApplication.isProtectedDataAvailable` on iOS, which is false while a
    /// locked device keeps protected files encrypted. Always true on the Mac:
    /// it has no per-file lock state, and a running app's container stays
    /// readable for as long as the user is logged in.
    static var isAvailable: Bool {
        #if os(iOS)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }
}
