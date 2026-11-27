import Foundation
import Network
import os.signpost

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

// MARK: - Sync Timing

struct SyncPhaseTimer {
    let name: String
    let startedAt: CFAbsoluteTime
}

struct SyncPhaseTiming: Equatable {
    let name: String
    let duration: TimeInterval
    let detail: String?
}

/// How a sync run ended, for the run's timing summary. Built from counts, flags
/// and `Log.redact(error:)`, never from an error's description: the summary goes
/// through `Log`, which publishes the finished string (`%{public}@`), and a
/// provider error's description can carry request details. The run outcome used
/// to be a `String`, and six call sites interpolated `error.localizedDescription`
/// into it past `LogRedactionTests`' scan, which reads `Log.` calls only
/// (architecture review 2026-11, observability-errors#5, security-privacy#4).
/// The summary is logged at info today, so nothing of it reaches a Release log;
/// raising that level is safe only because of this type.
enum SyncRunOutcome {
    /// An incremental run that saved what it fetched.
    case incrementalSuccess(newMessages: Int, labelRecords: Int, continuation: Bool, warnings: Bool)
    /// An initial sync that saved what it fetched.
    case initialSuccess(messages: Int, conversations: Int, warnings: Bool)
    /// No cursor and no budget for the initial sync: handed to a processing task.
    case initialFallbackDeferred
    /// No cursor, so the run performed the initial sync instead.
    case initialFallback(incomplete: Bool)
    /// The history ID expired and the recovery was handed to a processing task.
    case historyRecoveryDeferred
    /// The history ID expired and the run recovered the mailbox.
    case historyRecovery(warnings: Bool)
    /// The run threw. Rendered as the error's domain and code, never its text.
    case failed(Error)

    /// The `outcome=` field of the summary line.
    var summaryText: String {
        switch self {
        case let .incrementalSuccess(newMessages, labelRecords, continuation, warnings):
            return "success newMessages=\(newMessages) labelRecords=\(labelRecords) continuation=\(continuation) warnings=\(warnings)"
        case let .initialSuccess(messages, conversations, warnings):
            return "success messages=\(messages) conversations=\(conversations) warnings=\(warnings)"
        case .initialFallbackDeferred:
            return "initialFallback deferred=true"
        case let .initialFallback(incomplete):
            return "initialFallback incomplete=\(incomplete)"
        case .historyRecoveryDeferred:
            return "historyRecovery deferred=true"
        case let .historyRecovery(warnings):
            return "historyRecovery warnings=\(warnings)"
        case let .failed(error):
            return "failed error=\(Log.redact(error: error))"
        }
    }
}

struct SyncTimingRecorder {
    let syncType: String
    let runStartedAt: CFAbsoluteTime
    private(set) var phases: [SyncPhaseTiming] = []

    init(syncType: String, runStartedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        self.syncType = syncType
        self.runStartedAt = runStartedAt
    }

    func start(_ name: String) -> SyncPhaseTimer {
        SyncPhaseTimer(name: name, startedAt: CFAbsoluteTimeGetCurrent())
    }

    mutating func finish(_ timer: SyncPhaseTimer, detail: String? = nil) {
        let duration = CFAbsoluteTimeGetCurrent() - timer.startedAt
        phases.append(SyncPhaseTiming(name: timer.name, duration: duration, detail: detail))

        var message = "Sync timing [\(syncType)] \(timer.name)=\(Self.formatDuration(duration))"
        if let detail, !detail.isEmpty {
            message += " \(detail)"
        }
        Log.info(message, category: .sync)
    }

    func finishRun(outcome: SyncRunOutcome) {
        let totalDuration = CFAbsoluteTimeGetCurrent() - runStartedAt
        Log.info(summary(totalDuration: totalDuration, outcome: outcome), category: .sync)
    }

    func summary(totalDuration: TimeInterval, outcome: SyncRunOutcome) -> String {
        let phaseSummary = phases
            .map { phase in
                var value = "\(phase.name)=\(Self.formatDuration(phase.duration))"
                if let detail = phase.detail, !detail.isEmpty {
                    value += " \(detail)"
                }
                return value
            }
            .joined(separator: ", ")

        let suffix = phaseSummary.isEmpty ? "" : "; \(phaseSummary)"
        return "Sync timing [\(syncType)] total=\(Self.formatDuration(totalDuration)) outcome=\(outcome.summaryText)\(suffix)"
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3fs", duration)
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
