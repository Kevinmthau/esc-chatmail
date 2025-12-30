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
    let labelCache: [String: Label]
    let myAliases: Set<String>
    let syncStartTime: Date
    let progressHandler: (Double, String) -> Void
    let failureTracker: SyncFailureTracker

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
}

// Note: BatchProcessingResult is defined in BatchProcessor.swift
