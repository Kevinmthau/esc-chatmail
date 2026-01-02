import Foundation

/// Configuration for parallel message fetching behavior
struct FetchConfiguration: Sendable {
    let maxConcurrency: Int
    let batchSize: Int
    let timeout: TimeInterval
    let retryAttempts: Int
    let priorityBoost: Bool

    /// Default balanced configuration
    static let `default` = FetchConfiguration(
        maxConcurrency: 4,
        batchSize: 50,
        timeout: 30,
        retryAttempts: 3,
        priorityBoost: false
    )

    /// Aggressive configuration for fast networks
    static let aggressive = FetchConfiguration(
        maxConcurrency: 8,
        batchSize: 100,
        timeout: 45,
        retryAttempts: 2,
        priorityBoost: true
    )

    /// Conservative configuration for slow/unreliable networks
    static let conservative = FetchConfiguration(
        maxConcurrency: 2,
        batchSize: 25,
        timeout: 60,
        retryAttempts: 5,
        priorityBoost: false
    )
}
