import Foundation

/// Utility for safe file system operations with automatic error logging.
/// Replaces silent `try?` patterns with explicit error handling.
///
/// Usage:
/// ```swift
/// // Instead of:
/// try? FileManager.default.createDirectory(at: url, ...)
///
/// // Use:
/// FileSystemErrorHandler.createDirectory(at: url, category: .attachment)
/// ```
enum FileSystemErrorHandler {

    private static let fileManager = FileManager.default

    // MARK: - Directory Operations

    /// Creates a directory at the specified URL with intermediate directories.
    /// - Parameters:
    ///   - url: The URL at which to create the directory
    ///   - category: The log category for error reporting
    /// - Returns: `true` if the directory was created or already exists, `false` on failure
    @discardableResult
    static func createDirectory(at url: URL, category: LogCategory) -> Bool {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            Log.warning(
                "Failed to create directory at \(url.lastPathComponent)",
                category: category
            )
            return false
        }
    }

    /// Creates a directory at the specified path with intermediate directories.
    /// - Parameters:
    ///   - path: The path at which to create the directory
    ///   - category: The log category for error reporting
    /// - Returns: `true` if the directory was created or already exists, `false` on failure
    @discardableResult
    static func createDirectory(atPath path: String, category: LogCategory) -> Bool {
        do {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            return true
        } catch {
            Log.warning(
                "Failed to create directory at \(path)",
                category: category
            )
            return false
        }
    }

    // MARK: - File Removal

    /// Removes the item at the specified URL.
    /// Logs a warning if the removal fails (except for "file not found" which is expected).
    /// - Parameters:
    ///   - url: The URL of the item to remove
    ///   - category: The log category for error reporting
    static func removeItem(at url: URL, category: LogCategory) {
        do {
            try fileManager.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // File doesn't exist - this is often expected, so just debug log
            Log.debug("Item to remove does not exist: \(url.lastPathComponent)", category: category)
        } catch {
            Log.warning(
                "Failed to remove item at \(url.lastPathComponent)",
                category: category
            )
        }
    }

    /// Removes the item at the specified path.
    /// - Parameters:
    ///   - path: The path of the item to remove
    ///   - category: The log category for error reporting
    static func removeItem(atPath path: String, category: LogCategory) {
        do {
            try fileManager.removeItem(atPath: path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            Log.debug("Item to remove does not exist: \(path)", category: category)
        } catch {
            Log.warning(
                "Failed to remove item at \(path)",
                category: category
            )
        }
    }

    // MARK: - Data Loading

    /// Loads data from the specified URL.
    /// - Parameters:
    ///   - url: The URL to load data from
    ///   - category: The log category for error reporting
    /// - Returns: The data if successfully loaded, `nil` on failure
    static func loadData(from url: URL, category: LogCategory) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // File not found is often expected (cache miss), use debug level
            Log.debug("File not found: \(url.lastPathComponent)", category: category)
            return nil
        } catch {
            Log.warning(
                "Failed to load data from \(url.lastPathComponent)",
                category: category
            )
            return nil
        }
    }

    // MARK: - Data Writing

    /// Writes data to the specified URL.
    /// - Parameters:
    ///   - data: The data to write
    ///   - url: The URL to write to
    ///   - options: Writing options (default: .atomic for safety)
    ///   - category: The log category for error reporting
    /// - Returns: `true` if successfully written, `false` on failure
    @discardableResult
    static func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic, category: LogCategory) -> Bool {
        do {
            try data.write(to: url, options: options)
            return true
        } catch {
            Log.warning(
                "Failed to write data to \(url.lastPathComponent)",
                category: category
            )
            return false
        }
    }

    // MARK: - File Existence & Attributes

    /// Checks if a file exists at the specified URL.
    /// - Parameter url: The URL to check
    /// - Returns: `true` if the file exists
    static func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    /// Checks if a file exists at the specified path.
    /// - Parameter path: The path to check
    /// - Returns: `true` if the file exists
    static func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    /// Gets the size of a file at the specified URL.
    /// - Parameters:
    ///   - url: The URL of the file
    ///   - category: The log category for error reporting
    /// - Returns: The file size in bytes, or `nil` if the file doesn't exist or can't be read
    static func fileSize(at url: URL, category: LogCategory) -> Int? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.size] as? Int
        } catch {
            Log.debug("Failed to get file size for \(url.lastPathComponent)", category: category)
            return nil
        }
    }

    // MARK: - File Moving/Copying

    /// Moves a file from one URL to another.
    /// - Parameters:
    ///   - sourceURL: The source URL
    ///   - destinationURL: The destination URL
    ///   - category: The log category for error reporting
    /// - Returns: `true` if successfully moved, `false` on failure
    @discardableResult
    static func moveItem(from sourceURL: URL, to destinationURL: URL, category: LogCategory) -> Bool {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return true
        } catch {
            Log.warning(
                "Failed to move \(sourceURL.lastPathComponent) to \(destinationURL.lastPathComponent)",
                category: category
            )
            return false
        }
    }

    /// Copies a file from one URL to another.
    /// - Parameters:
    ///   - sourceURL: The source URL
    ///   - destinationURL: The destination URL
    ///   - category: The log category for error reporting
    /// - Returns: `true` if successfully copied, `false` on failure
    @discardableResult
    static func copyItem(from sourceURL: URL, to destinationURL: URL, category: LogCategory) -> Bool {
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            return true
        } catch {
            Log.warning(
                "Failed to copy \(sourceURL.lastPathComponent) to \(destinationURL.lastPathComponent)",
                category: category
            )
            return false
        }
    }

    // MARK: - Directory Contents

    /// Lists the contents of a directory.
    /// - Parameters:
    ///   - url: The directory URL
    ///   - category: The log category for error reporting
    /// - Returns: Array of URLs for items in the directory, or empty array on failure
    static func contentsOfDirectory(at url: URL, category: LogCategory) -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch {
            Log.debug("Failed to list contents of \(url.lastPathComponent)", category: category)
            return []
        }
    }
}
