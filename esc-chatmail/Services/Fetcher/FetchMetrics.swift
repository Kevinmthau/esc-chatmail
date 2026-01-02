import Foundation

/// Metrics for monitoring fetch performance
struct FetchMetrics: Sendable {
    let totalFetched: Int
    let totalErrors: Int
    let averageFetchTime: TimeInterval
    let activeTaskCount: Int
    let queuedTaskCount: Int

    /// Error rate as a percentage (0.0 to 1.0)
    var errorRate: Double {
        guard totalFetched > 0 else { return 0 }
        return Double(totalErrors) / Double(totalFetched)
    }

    /// Messages fetched per second
    var throughput: Double {
        guard averageFetchTime > 0 else { return 0 }
        return 1.0 / averageFetchTime
    }
}
