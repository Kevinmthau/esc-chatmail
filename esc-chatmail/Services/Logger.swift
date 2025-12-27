import Foundation
import os.log

// MARK: - Log Level

/// Log levels in order of increasing severity
enum LogLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }

    var prefix: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

// MARK: - Log Category

/// Categories for filtering and organizing logs
enum LogCategory: String {
    case sync = "Sync"
    case api = "API"
    case coreData = "CoreData"
    case auth = "Auth"
    case ui = "UI"
    case attachment = "Attachment"
    case message = "Message"
    case conversation = "Conversation"
    case background = "Background"
    case performance = "Performance"
    case general = "General"

    var subsystem: String {
        "com.esc.chatmail.\(rawValue.lowercased())"
    }
}

// MARK: - Logger Configuration

/// Configuration for the logging system
struct LoggerConfiguration {
    /// Minimum level to log (messages below this level are ignored)
    var minimumLevel: LogLevel

    /// Whether to include file/line information in logs
    var includeLocation: Bool

    /// Whether to include timestamps in console output
    var includeTimestamp: Bool

    /// Categories to enable (nil means all categories)
    var enabledCategories: Set<LogCategory>?

    /// Default configuration for debug builds
    static let debug = LoggerConfiguration(
        minimumLevel: .debug,
        includeLocation: true,
        includeTimestamp: true,
        enabledCategories: nil
    )

    /// Default configuration for release builds
    static let release = LoggerConfiguration(
        minimumLevel: .warning,
        includeLocation: false,
        includeTimestamp: false,
        enabledCategories: nil
    )

    /// Current active configuration
    #if DEBUG
    static var current = LoggerConfiguration.debug
    #else
    static var current = LoggerConfiguration.release
    #endif
}

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

    // MARK: - Specialized Logging Methods

    /// Log a performance measurement
    static func performance(
        _ operation: String,
        duration: TimeInterval,
        itemCount: Int? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var message = "\(operation) completed in \(String(format: "%.2f", duration))s"
        if let count = itemCount, duration > 0 {
            let throughput = Double(count) / duration
            message += " (\(count) items, \(String(format: "%.0f", throughput)) items/sec)"
        }
        log(level: .info, message: message, category: .performance, error: nil, file: file, function: function, line: line)
    }

    /// Log an API request/response
    static func api(
        _ method: String,
        endpoint: String,
        statusCode: Int? = nil,
        error: Error? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var message = "\(method) \(endpoint)"
        if let code = statusCode {
            message += " -> \(code)"
        }
        let level: LogLevel = error != nil ? .error : (statusCode ?? 200) >= 400 ? .warning : .debug
        log(level: level, message: message, category: .api, error: error, file: file, function: function, line: line)
    }

    /// Log sync progress
    static func sync(
        _ phase: String,
        progress: Double? = nil,
        detail: String? = nil,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        var message = phase
        if let progress = progress {
            message += " (\(Int(progress * 100))%)"
        }
        if let detail = detail {
            message += " - \(detail)"
        }
        log(level: .info, message: message, category: .sync, error: nil, file: file, function: function, line: line)
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
            fullMessage += " | Error: \(error.localizedDescription)"
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

        // Also print to stdout for Xcode console with formatting
        #if DEBUG
        printToConsole(level: level, category: category, message: fullMessage, config: config)
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

// MARK: - Convenience Extensions

extension Log {

    /// Measure and log the duration of an operation
    static func measure<T>(
        _ operation: String,
        category: LogCategory = .performance,
        block: () throws -> T
    ) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let duration = CFAbsoluteTimeGetCurrent() - start
        performance(operation, duration: duration)
        return result
    }

    /// Measure and log the duration of an async operation
    static func measureAsync<T>(
        _ operation: String,
        category: LogCategory = .performance,
        block: () async throws -> T
    ) async rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await block()
        let duration = CFAbsoluteTimeGetCurrent() - start
        performance(operation, duration: duration)
        return result
    }
}

// MARK: - Scoped Logger

/// A logger scoped to a specific category for cleaner usage within a class
struct ScopedLogger {
    let category: LogCategory

    func debug(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        Log.debug(message(), category: category, file: file, function: function, line: line)
    }

    func info(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        Log.info(message(), category: category, file: file, function: function, line: line)
    }

    func warning(_ message: @autoclosure () -> String, file: String = #file, function: String = #function, line: Int = #line) {
        Log.warning(message(), category: category, file: file, function: function, line: line)
    }

    func error(_ message: @autoclosure () -> String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        Log.error(message(), category: category, error: error, file: file, function: function, line: line)
    }
}

extension LogCategory {
    /// Get a scoped logger for this category
    var logger: ScopedLogger {
        ScopedLogger(category: self)
    }
}
