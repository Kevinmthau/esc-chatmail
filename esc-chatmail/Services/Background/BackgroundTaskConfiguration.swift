import Foundation
import BackgroundTasks

/// Configuration for a background task
struct BackgroundTaskConfiguration {
    /// Unique identifier for the task
    let identifier: String

    /// Type of background task
    let taskType: TaskType

    /// How long to wait before first execution
    let interval: TimeInterval

    /// Whether the task requires network
    let requiresNetworkConnectivity: Bool

    /// Whether the task requires external power
    let requiresExternalPower: Bool

    /// Task types supported by iOS
    enum TaskType {
        case appRefresh
        case processing
    }

    // MARK: - Common Configurations

    /// Creates a daily processing task configuration
    static func dailyProcessing(
        identifier: String,
        requiresNetwork: Bool = false,
        requiresPower: Bool = false
    ) -> BackgroundTaskConfiguration {
        BackgroundTaskConfiguration(
            identifier: identifier,
            taskType: .processing,
            interval: 24 * 60 * 60,  // 1 day
            requiresNetworkConnectivity: requiresNetwork,
            requiresExternalPower: requiresPower
        )
    }

    /// Creates a weekly processing task configuration
    static func weeklyProcessing(
        identifier: String,
        requiresNetwork: Bool = false,
        requiresPower: Bool = true
    ) -> BackgroundTaskConfiguration {
        BackgroundTaskConfiguration(
            identifier: identifier,
            taskType: .processing,
            interval: 7 * 24 * 60 * 60,  // 1 week
            requiresNetworkConnectivity: requiresNetwork,
            requiresExternalPower: requiresPower
        )
    }

    /// Creates an app refresh task configuration
    static func appRefresh(
        identifier: String,
        interval: TimeInterval = 15 * 60  // 15 minutes
    ) -> BackgroundTaskConfiguration {
        BackgroundTaskConfiguration(
            identifier: identifier,
            taskType: .appRefresh,
            interval: interval,
            requiresNetworkConnectivity: true,
            requiresExternalPower: false
        )
    }
}
