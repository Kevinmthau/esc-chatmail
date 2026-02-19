import Foundation

// MARK: - Logger Configuration

/// Configuration for the logging system
struct LoggerConfiguration {
    /// Minimum level to log (messages below this level are ignored)
    var minimumLevel: LogLevel

    /// Whether to include file/line information in logs
    var includeLocation: Bool

    /// Whether to include timestamps in console output
    var includeTimestamp: Bool

    /// Whether to mirror logs to stdout in debug builds.
    /// Keep disabled by default to avoid duplicate lines when OSLog is visible in Xcode.
    var mirrorToStdout: Bool

    /// Categories to enable (nil means all categories)
    var enabledCategories: Set<LogCategory>?

    /// Default configuration for debug builds
    static let debug = LoggerConfiguration(
        minimumLevel: .debug,
        includeLocation: true,
        includeTimestamp: true,
        mirrorToStdout: ProcessInfo.processInfo.environment["ESC_MIRROR_LOGS_TO_STDOUT"] == "1",
        enabledCategories: nil
    )

    /// Default configuration for release builds
    static let release = LoggerConfiguration(
        minimumLevel: .warning,
        includeLocation: false,
        includeTimestamp: false,
        mirrorToStdout: false,
        enabledCategories: nil
    )

    /// Current active configuration
    #if DEBUG
    static var current = LoggerConfiguration.debug
    #else
    static var current = LoggerConfiguration.release
    #endif
}
