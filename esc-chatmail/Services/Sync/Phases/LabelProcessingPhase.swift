import Foundation
import CoreData

/// Phase 3: Process label changes from history records
struct LabelProcessingPhase: SyncPhase {
    typealias Input = [HistoryRecord]
    typealias Output = Void

    let name = "Label Processing"
    let progressRange: ClosedRange<Double> = 0.7...0.8

    private let historyProcessor: HistoryProcessor
    private let log = LogCategory.sync.logger

    init(historyProcessor: HistoryProcessor) {
        self.historyProcessor = historyProcessor
    }

    func execute(
        input records: [HistoryRecord],
        context: SyncPhaseContext
    ) async throws {
        guard !records.isEmpty else { return }

        context.reportProgress(0, status: "Processing label changes...", phase: self)
        log.debug("Processing \(records.count) history records for label changes")

        for (index, record) in records.enumerated() {
            await historyProcessor.processLightweightOperations(
                record,
                in: context.coreDataContext,
                syncStartTime: context.syncStartTime
            )

            if index % 10 == 0 {
                let progress = Double(index) / Double(records.count)
                context.reportProgress(progress, status: "Processing label changes...", phase: self)
            }
        }

        context.reportProgress(1.0, status: "Labels processed", phase: self)
    }
}
