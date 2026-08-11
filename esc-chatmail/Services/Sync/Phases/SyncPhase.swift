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
    let sendAsAliases: [SendAsAlias]
    let modificationTransaction: ModificationTracker.Transaction?
    let allowsIntermediateContextSaves: Bool
    let syncStartTime: Date
    let progressHandler: (Double, String) -> Void
    let failureTracker: SyncFailureTracker
    /// The frozen history cursor this run started from; stamped onto deferred
    /// failure-ledger rows so recovery can bound re-enumeration.
    let sourceHistoryId: String?

    init(
        coreDataContext: NSManagedObjectContext,
        labelIds: Set<String>,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = [],
        modificationTransaction: ModificationTracker.Transaction? = nil,
        allowsIntermediateContextSaves: Bool = true,
        syncStartTime: Date,
        progressHandler: @escaping (Double, String) -> Void,
        failureTracker: SyncFailureTracker,
        sourceHistoryId: String? = nil
    ) {
        self.coreDataContext = coreDataContext
        self.labelIds = labelIds
        self.myAliases = myAliases
        self.sendAsAliases = sendAsAliases
        self.modificationTransaction = modificationTransaction
        self.allowsIntermediateContextSaves = allowsIntermediateContextSaves
        self.syncStartTime = syncStartTime
        self.progressHandler = progressHandler
        self.failureTracker = failureTracker
        self.sourceHistoryId = sourceHistoryId
    }

    /// Reports progress within the phase's progress range
    func reportProgress(_ localProgress: Double, status: String, phase: any SyncPhase) {
        let range = phase.progressRange
        let globalProgress = range.lowerBound + (localProgress * (range.upperBound - range.lowerBound))
        progressHandler(globalProgress, status)
    }
}

/// One bounded history-list request. `pageToken` resumes a model-v3
/// foreground checkpoint while `startHistoryId` remains the frozen Account
/// cursor until the terminal slice commits.
struct HistoryCollectionRequest {
    let startHistoryId: String
    let pageToken: String?
}

/// Result of one bounded history collection slice.
struct HistoryCollectionResult {
    let newMessageIds: [String]
    let records: [HistoryRecord]
    let latestHistoryId: String
    /// Gmail's token for the next slice. A non-nil token means the Account
    /// cursor must remain frozen and this token must be durably checkpointed.
    let nextPageToken: String?

    var wasTruncated: Bool { nextPageToken != nil }
}

// Note: BatchProcessingResult is defined in BatchProcessor.swift
