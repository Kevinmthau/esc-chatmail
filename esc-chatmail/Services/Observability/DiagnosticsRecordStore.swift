import Foundation

/// MetricKit's payloads, as `DiagnosticsPayloadProjection` keeps them, in files on the
/// device that the user can share (`DiagnosticsReport`). Nothing here sends anything
/// anywhere: there is no backend, and sending would be a privacy decision of its own.
///
/// Before it existed a shipped build kept nothing that said why it had been killed in the
/// background (jetsam, the watchdog, a background task's time running out) or how often
/// it hung: MetricKit was not subscribed to and telemetry was a no-op (architecture
/// review 2026-11, `observability-errors#1`).
///
/// - The files are in `Caches/Diagnostics`, which is not backed up and which the system
///   may clear; they hold no mail, so they are not account data and a sign-out leaves
///   them, as it leaves the preferences it keeps on purpose.
/// - Only this store's own files (`filePrefix`) are ever pruned or removed.
/// - At most `maxRecords` files and `maxBytes` in all: the oldest go first. A payload
///   larger than `maxBytes` by itself is not written.
/// - A write that fails is logged and dropped, never retried or thrown: the device may be
///   out of space, and a diagnostic must not add to the trouble.
///
/// `@unchecked Sendable`: `lock` serializes every file operation of the store; the stored
/// properties are immutable.
final class DiagnosticsRecordStore: @unchecked Sendable {
    static let filePrefix = "mx-"
    static let fileExtension = "json"

    static let shared = DiagnosticsRecordStore(directory: defaultDirectory)

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    let directory: URL
    private let maxRecords: Int
    private let maxBytes: Int
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        directory: URL,
        maxRecords: Int = 40,
        maxBytes: Int = 4_000_000,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.maxRecords = maxRecords
        self.maxBytes = maxBytes
        self.fileManager = fileManager
        self.now = now
    }

    /// Keeps the allowlisted part of a payload. Returns the file written, or nil when
    /// nothing was kept or the write failed.
    @discardableResult
    func record(kind: DiagnosticsPayloadProjection.Kind, payloadJSON: Data) -> URL? {
        guard let projected = DiagnosticsPayloadProjection.project(kind: kind, json: payloadJSON) else {
            Log.warning("MetricKit \(kind.rawValue) payload had nothing to keep", category: .performance)
            return nil
        }
        guard projected.count <= maxBytes else {
            Log.warning(
                "MetricKit \(kind.rawValue) payload of \(projected.count) bytes exceeds the store's cap; not kept",
                category: .performance
            )
            return nil
        }
        return lock.withLock {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(fileName(for: kind))
                try projected.write(to: url, options: [.atomic])
                pruneLocked(keeping: url)
                return url
            } catch {
                Log.warning(
                    "Could not keep a MetricKit \(kind.rawValue) record: \(Log.redact(error: error))",
                    category: .performance
                )
                return nil
            }
        }
    }

    /// The store's files, oldest first.
    func recordURLs() -> [URL] {
        lock.withLock { ownFilesLocked() }
    }

    /// Each file's name and contents, oldest first, read under the lock so a delivery
    /// arriving meanwhile cannot prune a file between the listing and its read. Nil
    /// contents is a file that could not be read.
    func recordContents() -> [(name: String, data: Data?)] {
        lock.withLock {
            ownFilesLocked().map { ($0.lastPathComponent, try? Data(contentsOf: $0)) }
        }
    }

    /// The file name sorts by time: milliseconds since 1970, zero-padded, then a random
    /// suffix so two payloads in one millisecond cannot collide.
    private func fileName(for kind: DiagnosticsPayloadProjection.Kind) -> String {
        let milliseconds = Int64((now().timeIntervalSince1970 * 1000).rounded())
        let stamp = String(format: "%015lld", milliseconds)
        let suffix = UUID().uuidString.prefix(8)
        return "\(Self.filePrefix)\(stamp)-\(kind.rawValue)-\(suffix).\(Self.fileExtension)"
    }

    private func ownFilesLocked() -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(Self.filePrefix) && $0.hasSuffix(".\(Self.fileExtension)") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// Removes the oldest files past the caps, never `written`: a clock set back makes the
    /// newest record's name sort first, and pruning by name alone deleted it at once.
    private func pruneLocked(keeping written: URL) {
        var files = ownFilesLocked().filter { $0 != written }.map { url -> (URL, Int) in
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return (url, size)
        }
        let writtenSize = (try? fileManager.attributesOfItem(atPath: written.path)[.size] as? Int) ?? 0
        var totalBytes = files.reduce(writtenSize) { $0 + $1.1 }
        while !files.isEmpty, files.count + 1 > maxRecords || totalBytes > maxBytes {
            let (oldest, size) = files.removeFirst()
            do {
                try fileManager.removeItem(at: oldest)
            } catch {
                Log.warning("Could not prune a MetricKit record: \(Log.redact(error: error))", category: .performance)
            }
            totalBytes -= size
        }
    }
}
