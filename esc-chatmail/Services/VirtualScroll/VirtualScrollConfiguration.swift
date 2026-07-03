import Foundation

// MARK: - Virtual Scroll Configuration
struct VirtualScrollConfiguration {
    let visibleItemCount: Int
    let bufferSize: Int
    let pageSize: Int
    let preloadThreshold: Int
    /// Upper bound on rows kept in the message window. Long scroll sessions
    /// previously grew the window without limit — every preload appended and
    /// nothing pruned. Only trimming that cannot shift the viewport is
    /// allowed against this cap (back-trim while extending upward).
    let maxWindowSize: Int

    /// - Parameter maxWindowSize: nil uses `max(200, pageSize * 6)`. Any
    ///   value is clamped to at least `visibleItemCount + 2·bufferSize +
    ///   2·pageSize` — configurations below that cause window-replace /
    ///   preload ping-pong (the config is injectable in tests).
    init(
        visibleItemCount: Int,
        bufferSize: Int,
        pageSize: Int,
        preloadThreshold: Int,
        maxWindowSize: Int? = nil
    ) {
        self.visibleItemCount = visibleItemCount
        self.bufferSize = bufferSize
        self.pageSize = pageSize
        self.preloadThreshold = preloadThreshold

        let minimumViableWindow = visibleItemCount + 2 * bufferSize + 2 * pageSize
        let requested = maxWindowSize ?? max(200, pageSize * 6)
        self.maxWindowSize = max(requested, minimumViableWindow)
    }

    static let `default` = VirtualScrollConfiguration(
        visibleItemCount: 20,
        bufferSize: 10,
        pageSize: 50,
        preloadThreshold: 5
    )
}
