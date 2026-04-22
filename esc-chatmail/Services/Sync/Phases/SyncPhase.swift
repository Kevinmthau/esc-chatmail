import Foundation
import CoreData

/// Protocol for composable sync phases
protocol SyncPhase {
    associatedtype Input
    associatedtype Output

    var name: String { get }
    var progressRange: ClosedRange<Double> { get }

    func execute(
        input: Input,
        context: SyncPhaseContext
    ) async throws -> Output
}

/// Shared context for sync phases
struct SyncPhaseContext {
    let coreDataContext: NSManagedObjectContext
    let labelIds: Set<String>
    let myAliases: Set<String>
    let modificationTransaction: ModificationTracker.Transaction?
    let syncStartTime: Date
    let progressHandler: (Double, String) -> Void
    let failureTracker: SyncFailureTracker

    init(
        coreDataContext: NSManagedObjectContext,
        labelIds: Set<String>,
        myAliases: Set<String>,
        modificationTransaction: ModificationTracker.Transaction? = nil,
        syncStartTime: Date,
        progressHandler: @escaping (Double, String) -> Void,
        failureTracker: SyncFailureTracker
    ) {
        self.coreDataContext = coreDataContext
        self.labelIds = labelIds
        self.myAliases = myAliases
        self.modificationTransaction = modificationTransaction
        self.syncStartTime = syncStartTime
        self.progressHandler = progressHandler
        self.failureTracker = failureTracker
    }

    /// Reports progress within the phase's progress range
    func reportProgress(_ localProgress: Double, status: String, phase: any SyncPhase) {
        let range = phase.progressRange
        let globalProgress = range.lowerBound + (localProgress * (range.upperBound - range.lowerBound))
        progressHandler(globalProgress, status)
    }
}

/// Result of history collection phase
struct HistoryCollectionResult {
    let newMessageIds: [String]
    let records: [HistoryRecord]
    let latestHistoryId: String
    /// True if history collection was truncated due to page limit.
    /// When truncated, latestHistoryId returns the starting ID so next sync retries from same point.
    let wasTruncated: Bool
}

// Note: BatchProcessingResult is defined in BatchProcessor.swift
