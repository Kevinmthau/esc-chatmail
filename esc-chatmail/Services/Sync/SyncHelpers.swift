import Foundation
import Network
import os.signpost


// MARK: - Sync State Actor

/// Thread-safe actor for managing sync state
actor SyncStateActor {
    private var isCurrentlySyncing = false
    private var syncTask: Task<Void, Error>?

    func beginSync() async -> Bool {
        guard !isCurrentlySyncing else {
            Log.debug("Sync already in progress, skipping", category: .sync)
            return false
        }
        isCurrentlySyncing = true
        return true
    }

    func endSync() {
        isCurrentlySyncing = false
        syncTask = nil
    }

    func setSyncTask(_ task: Task<Void, Error>?) {
        syncTask?.cancel()
        syncTask = task
    }

    func cancelCurrentSync() {
        syncTask?.cancel()
        syncTask = nil
        isCurrentlySyncing = false
    }

    func isSyncing() -> Bool {
        return isCurrentlySyncing
    }
}

// MARK: - Sync UI State

/// Observable state for sync UI updates (Main Actor only)
@MainActor
final class SyncUIState: ObservableObject {
    @Published var isSyncing = false
    @Published var syncProgress: Double = 0.0
    @Published var syncStatus: String = ""

    func update(isSyncing: Bool? = nil, progress: Double? = nil, status: String? = nil) {
        if let isSyncing = isSyncing { self.isSyncing = isSyncing }
        if let progress = progress { self.syncProgress = progress }
        if let status = status { self.syncStatus = status }
    }

    func reset() {
        isSyncing = false
        syncProgress = 0.0
        syncStatus = ""
    }
}

// MARK: - Core Data Performance Logger

/// Logger for tracking Core Data performance metrics
final class CoreDataPerformanceLogger: Sendable {
    static let shared = CoreDataPerformanceLogger()

    private let log = OSLog(subsystem: "com.esc.inboxchat", category: "CoreData")
    private let signpostLog = OSLog(subsystem: "com.esc.inboxchat", category: .pointsOfInterest)

    #if DEBUG
    private let isEnabled = true
    #else
    private let isEnabled = false
    #endif

    private init() {}

    /// Start timing an operation
    func beginOperation(_ name: StaticString) -> OSSignpostID {
        let signpostID = OSSignpostID(log: signpostLog)
        if isEnabled {
            os_signpost(.begin, log: signpostLog, name: name, signpostID: signpostID)
        }
        return signpostID
    }

    /// End timing an operation
    func endOperation(_ name: StaticString, signpostID: OSSignpostID) {
        if isEnabled {
            os_signpost(.end, log: signpostLog, name: name, signpostID: signpostID)
        }
    }

    /// Log a fetch operation with details
    func logFetch(entity: String, count: Int, duration: TimeInterval, predicate: String? = nil) {
        guard isEnabled else { return }

        let predicateInfo = predicate ?? "none"
        os_log(.info, log: log,
               "📊 FETCH %{public}@: %d objects in %.3fs (predicate: %{public}@)",
               entity, count, duration, predicateInfo)
    }

    /// Log a save operation
    func logSave(insertions: Int, updates: Int, deletions: Int, duration: TimeInterval) {
        guard isEnabled else { return }

        os_log(.info, log: log,
               "📊 SAVE: +%d ~%d -%d in %.3fs",
               insertions, updates, deletions, duration)
    }

    /// Log a batch operation
    func logBatchOperation(type: String, entity: String, count: Int, duration: TimeInterval) {
        guard isEnabled else { return }

        os_log(.info, log: log,
               "📊 BATCH %{public}@ %{public}@: %d objects in %.3fs",
               type, entity, count, duration)
    }

    /// Log sync metrics summary
    func logSyncSummary(messagesProcessed: Int, conversationsUpdated: Int, totalDuration: TimeInterval) {
        os_log(.info, log: log,
               "📊 SYNC COMPLETE: %d messages, %d conversations in %.2fs (%.0f msg/s)",
               messagesProcessed, conversationsUpdated, totalDuration,
               totalDuration > 0 ? Double(messagesProcessed) / totalDuration : 0)
    }
}

// MARK: - Network Monitor

/// Actor for managing network connectivity monitoring
/// Provides thread-safe access to network reachability state
actor NetworkMonitorService {
    private let networkMonitor = NWPathMonitor()
    private nonisolated let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    private var _isReachable = true

    init() {
        Self.setupNetworkMonitoring(
            monitor: networkMonitor,
            queue: monitorQueue,
            onStatusChange: { [weak self] isReachable, status, isExpensive in
                Task { [weak self] in
                    await self?.setReachable(isReachable)
                }
                if !isExpensive && isReachable {
                    Log.debug("Network is reachable", category: .general)
                } else {
                    Log.debug("Network status: \(status), expensive: \(isExpensive)", category: .general)
                }
            }
        )
    }

    deinit {
        networkMonitor.cancel()
    }

    /// Static helper to set up network monitoring without actor isolation issues
    private static func setupNetworkMonitoring(
        monitor: NWPathMonitor,
        queue: DispatchQueue,
        onStatusChange: @escaping @Sendable (Bool, NWPath.Status, Bool) -> Void
    ) {
        monitor.pathUpdateHandler = { path in
            onStatusChange(path.status == .satisfied, path.status, path.isExpensive)
        }
        monitor.start(queue: queue)
    }

    private func setReachable(_ reachable: Bool) {
        _isReachable = reachable
    }

    func isNetworkAvailable() -> Bool {
        return _isReachable
    }
}

// MARK: - Array Chunking Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
