import Foundation

// MARK: - Virtual Scroll Configuration
struct VirtualScrollConfiguration {
    let visibleItemCount: Int
    let bufferSize: Int
    let pageSize: Int
    let preloadThreshold: Int

    static let `default` = VirtualScrollConfiguration(
        visibleItemCount: 20,
        bufferSize: 10,
        pageSize: 50,
        preloadThreshold: 5
    )
}
