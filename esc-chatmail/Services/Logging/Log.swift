import Foundation
import os.log

// MARK: - Log

/// Main logging interface
///
/// Usage:
/// ```
/// Log.debug("Processing message", category: .message)
/// Log.info("Sync completed", category: .sync)
/// Log.warning("Rate limited, retrying", category: .api)
/// Log.error("Failed to save", category: .coreData, error: error)
/// ```
enum Log {

    // MARK: - OSLog instances (cached per category)

    private static var loggers: [LogCategory: OSLog] = [:]
    private static let loggersLock = NSLock()

    private static func logger(for category: LogCategory) -> OSLog {
        loggersLock.lock()
        defer { loggersLock.unlock() }

        if let existing = loggers[category] {
            return existing
        }

        let newLogger = OSLog(subsystem: category.subsystem, category: category.rawValue)
        loggers[category] = newLogger
        return newLogger
    }

    // MARK: - Public Logging Methods

    /// Log a debug message (verbose, development only)
    static func debug(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .debug, message: message(), category: category, error: nil, file: file, function: function, line: line)
    }

    /// Log an info message (normal operation events)
    static func info(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .info, message: message(), category: category, error: nil, file: file, function: function, line: line)
    }

    /// Log a warning message (potential issues)
    static func warning(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .warning, message: message(), category: category, error: nil, file: file, function: function, line: line)
    }

    /// Log an error message (failures)
    static func error(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        error: Error? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .error, message: message(), category: category, error: error, file: file, function: function, line: line)
    }

    /// Log an opt-in diagnostic message for especially noisy traces.
    static func diagnostic(
        _ area: LogDiagnosticArea,
        level: LogLevel = .debug,
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        guard LoggerConfiguration.current.isDiagnosticEnabled(area) else { return }
        log(level: level, message: message(), category: category, error: nil, file: file, function: function, line: line)
    }

    // MARK: - Core Logging

    private static func log(
        level: LogLevel,
        message: String,
        category: LogCategory,
        error: Error?,
        file: String,
        function: String,
        line: Int
    ) {
        let config = LoggerConfiguration.current

        // Check minimum level
        guard level >= config.minimumLevel else { return }

        // Check category filter
        if let enabledCategories = config.enabledCategories, !enabledCategories.contains(category) {
            return
        }

        // Build the full message
        var fullMessage = message

        // Add error details if present
        if let error = error {
            fullMessage += " | Error: \(Log.redact(error: error))"
            if let nsError = error as NSError? {
                fullMessage += " (code: \(nsError.code))"
            }
        }

        // Add location if configured
        if config.includeLocation {
            let filename = (file as NSString).lastPathComponent
            fullMessage += " [\(filename):\(line)]"
        }

        // Log to OSLog (system console, visible in Console.app)
        let osLog = logger(for: category)
        os_log("%{public}@", log: osLog, type: level.osLogType, fullMessage)

        // Optionally mirror to stdout for local debugging.
        // Disabled by default to avoid duplicate lines in Xcode when OSLog is also visible.
        #if DEBUG
        if config.mirrorToStdout {
            printToConsole(level: level, category: category, message: fullMessage, config: config)
        }
        #endif
    }

    #if DEBUG
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func printToConsole(
        level: LogLevel,
        category: LogCategory,
        message: String,
        config: LoggerConfiguration
    ) {
        var parts: [String] = []

        if config.includeTimestamp {
            parts.append(dateFormatter.string(from: Date()))
        }

        parts.append("[\(level.prefix)]")
        parts.append("[\(category.rawValue)]")
        parts.append(message)

        print(parts.joined(separator: " "))
    }
    #endif
}
