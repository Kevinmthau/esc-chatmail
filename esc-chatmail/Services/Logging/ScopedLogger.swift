import Foundation

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
