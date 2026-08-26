import SwiftUI
import CoreData
import Combine

// MARK: - Dataset reconciliation and post-sync validation

extension VirtualScrollState {
    @discardableResult
    func reconcileWindowAfterDatasetMutation(
        window: MessageWindow,
        shouldFollowLatestWindow: Bool
    ) async -> Bool {
        guard canStartAutomaticReconciliation(window) else { return false }
        if shouldFollowLatestWindow && self.shouldFollowLatestWindow(window) {
            let requiredFollowIntentRevision = followIntentRevision
            let didLoadLatest = await loadLatestWindow(
                forceViewContext: true,
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
            if didLoadLatest {
                return true
            }
            guard !isCurrentFollowIntent(requiredFollowIntentRevision) else {
                return false
            }
        }

        guard canRestoreCapturedWindow(window) else { return false }
        return await reloadHistoricalWindowClamped(
            window,
            preferPendingConversationMessages: true
        )
    }

    func scheduleDeferredDatasetReconciliationIfNeeded() {
        guard needsDatasetReconciliationAfterCurrentLoad,
              let window = messageWindow else {
            return
        }

        needsDatasetReconciliationAfterCurrentLoad = false
        let loadIntent = currentWindowLoadIntent
        windowLoadLifecycle = .idle
        let shouldFollowLatestWindow = shouldFollowLatestWindow(window)
        taskManager.run(datasetReconcileTaskKey) { [weak self] in
            guard let self else { return }
            guard self.canRestoreCapturedWindow(window) else { return }
            switch loadIntent {
            case .latest(let requiredFollowIntentRevision):
                let didLoadLatest = await self.loadLatestWindow(
                    forceViewContext: true,
                    requiredFollowIntentRevision: requiredFollowIntentRevision
                )
                if !didLoadLatest,
                   !self.isCurrentFollowIntent(requiredFollowIntentRevision),
                   self.canRestoreCapturedWindow(window) {
                    _ = await self.reloadHistoricalWindowClamped(
                        window,
                        preferPendingConversationMessages: true
                    )
                }
            case .range(let range):
                _ = await self.loadWindow(
                    startIndex: range.lowerBound,
                    endIndex: range.upperBound,
                    preferPendingConversationMessages: true
                )
            case nil:
                await self.reconcileWindowAfterDatasetMutation(
                    window: window,
                    shouldFollowLatestWindow: shouldFollowLatestWindow
                )
            }
        }
    }

    func scheduleUnclassifiedRefreshCountReconciliationIfNeeded() {
        guard needsUnclassifiedRefreshCountReconciliation,
              isInitialLoadComplete,
              !isLoadingMore,
              messageWindow != nil else {
            return
        }

        taskManager.run(unclassifiedRefreshCountTaskKey) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
            await self?.reconcileUnclassifiedRefreshCountIfNeeded()
        }
    }

    private func reconcileUnclassifiedRefreshCountIfNeeded() async {
        guard needsUnclassifiedRefreshCountReconciliation else { return }
        needsUnclassifiedRefreshCountReconciliation = false

        let observedCount = await loadTotalMessageCount(
            preferPendingConversationMessages: hasPendingInsertedMessagesInConversation
        )
        guard !Task.isCancelled, let observedCount else { return }
        guard observedCount != totalMessageCount else { return }

        messageDatasetGeneration &+= 1
        guard let window = messageWindow else { return }
        let shouldFollowLatestWindow = shouldFollowLatestWindow(window)

        if isLoadingMore {
            needsDatasetReconciliationAfterCurrentLoad = true
            return
        }

        await reconcileWindowAfterDatasetMutation(
            window: window,
            shouldFollowLatestWindow: shouldFollowLatestWindow
        )
    }

    func schedulePostSyncDatasetReconciliationIfNeeded(
        syncDidComplete: Bool = false
    ) {
        if syncDidComplete {
            needsPostSyncDatasetReconciliation = true
            postSyncValidationRetryCount = 0
        }
        guard needsPostSyncDatasetReconciliation else { return }
        guard isInitialLoadComplete,
              !isLoadingMore,
              let window = messageWindow else {
            return
        }

        needsPostSyncDatasetReconciliation = false
        let shouldFollowLatestWindow = shouldFollowLatestWindow(window)
        taskManager.run(postSyncValidationTaskKey) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
            guard let self else { return }
            await self.validateWindowAfterSync(
                window: window,
                shouldFollowLatestWindow: shouldFollowLatestWindow
            )
        }
    }

    func validateWindowAfterSync(
        window: MessageWindow,
        shouldFollowLatestWindow: Bool
    ) async {
        let page = await loadPage(
            window.startIndex..<window.endIndex,
            preferPendingConversationMessages: hasPendingInsertedMessagesInConversation
        )
        guard !Task.isCancelled else { return }

        guard page.fetchErrorDescription == nil else {
            needsPostSyncDatasetReconciliation = true
            Log.diagnostic(
                .chatView,
                level: .error,
                "VirtualScroll post-sync validation failed conv=\(conversationId) error=\(page.fetchErrorDescription ?? "Unknown fetch error")",
                category: .ui
            )
            if postSyncValidationRetryCount < maximumAutomaticPostSyncValidationRetryCount {
                postSyncValidationRetryCount += 1
                schedulePostSyncDatasetReconciliationIfNeeded()
            }
            return
        }
        guard let currentWindow = messageWindow,
              currentWindow.startIndex == window.startIndex,
              currentWindow.endIndex == window.endIndex,
              currentWindow.messageIDs == window.messageIDs else {
            needsPostSyncDatasetReconciliation = true
            schedulePostSyncDatasetReconciliationIfNeeded()
            return
        }
        guard page.totalCount != totalMessageCount ||
                page.messageIDs != window.messageIDs else {
            postSyncValidationRetryCount = 0
            return
        }

        messageDatasetGeneration &+= 1
        if isLoadingMore {
            needsDatasetReconciliationAfterCurrentLoad = true
            needsPostSyncDatasetReconciliation = true
            return
        }

        let didReconcile = await reconcileWindowAfterDatasetMutation(
            window: window,
            shouldFollowLatestWindow: shouldFollowLatestWindow
        )
        guard !Task.isCancelled else { return }
        guard !didReconcile else {
            postSyncValidationRetryCount = 0
            return
        }

        needsPostSyncDatasetReconciliation = true
        if postSyncValidationRetryCount < maximumAutomaticPostSyncValidationRetryCount {
            postSyncValidationRetryCount += 1
            schedulePostSyncDatasetReconciliationIfNeeded()
        }
    }

    @discardableResult
    func reloadHistoricalWindowClamped(
        _ window: MessageWindow,
        preferPendingConversationMessages: Bool,
        datasetRetryAttemptsRemaining: Int = 1
    ) async -> Bool {
        let loadGeneration = beginWindowLoad(
            intent: .range(window.startIndex..<window.endIndex)
        )
        let expectedDatasetGeneration = messageDatasetGeneration
        let loadedTotalCount = await loadTotalMessageCount(
            preferPendingConversationMessages: preferPendingConversationMessages
        )
        guard !Task.isCancelled else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return false
        }
        guard loadGeneration == windowLoadGeneration else { return false }
        guard expectedDatasetGeneration == messageDatasetGeneration else {
            guard datasetRetryAttemptsRemaining > 0 else {
                finishWindowLoadFailure(
                    operation: "historical window metadata",
                    description: "message dataset kept changing while loading"
                )
                return false
            }
            return await reloadHistoricalWindowClamped(
                window,
                preferPendingConversationMessages:
                    preferPendingConversationMessages || hasPendingInsertedMessagesInConversation,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining - 1
            )
        }
        guard let totalCount = loadedTotalCount else {
            finishWindowLoadFailure(
                operation: "dataset reconciliation metadata",
                description: "unable to fetch message count"
            )
            return false
        }

        let desiredWindowCount = max(1, window.endIndex - window.startIndex)
        let latestPossibleStart = max(0, totalCount - desiredWindowCount)
        let adjustedStartIndex = min(window.startIndex, latestPossibleStart)
        let adjustedEndIndex = min(
            totalCount,
            adjustedStartIndex + desiredWindowCount
        )
        return await loadWindow(
            startIndex: adjustedStartIndex,
            endIndex: adjustedEndIndex,
            preferPendingConversationMessages: preferPendingConversationMessages,
            generation: loadGeneration,
            datasetGeneration: expectedDatasetGeneration,
            datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining
        ) != nil
    }
}
