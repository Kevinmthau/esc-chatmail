import Foundation
import CoreData

// MARK: - Initial window load

extension VirtualScrollState {
    func retryInitialLoad() {
        loadInitialMessages()
    }

    func loadInitialMessages() {
        finishInitialLoadSignpost(outcome: "restarted")
        initialLoadSignpostInterval = ChatViewPerformanceSignposts.beginInitialLoad(
            conversationID: conversationId
        )
        initialLoadPhase = .loading
        initialLoadFailureReason = nil
        // Claiming the lifecycle bumps the generation, like every other
        // claim (beginWindowLoad, cleanup): an in-flight window load's
        // generation guards then retire it quietly instead of letting its
        // terminal force .idle over this initial load — the mirror image of
        // the superseded-publish drop in publishInitialWindow below.
        windowLoadGeneration &+= 1
        windowLoadLifecycle = .loadingInitialWindow
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll initial load start conv=\(conversationId) position=\(initialWindowPosition.diagnosticName)",
            category: .ui
        )

        taskManager.run("loadInitial") { [weak self] in
            guard let self = self else { return }

            for retryCount in 0...self.maximumAutomaticInitialLoadRetryCount {
                let result = await self.loadInitialWindowAttempt()

                guard !Task.isCancelled else { return }

                switch result {
                case .success(let loadedWindow):
                    self.publishInitialWindow(loadedWindow)
                    return

                case .failure(let failure):
                    if retryCount < self.maximumAutomaticInitialLoadRetryCount {
                        Log.diagnostic(
                            .chatView,
                            level: .warning,
                            "VirtualScroll initial load retry conv=\(self.conversationId) attempt=\(retryCount + 1) reason=\(failure.diagnosticDescription)",
                            category: .ui
                        )

                        do {
                            try await Task.sleep(
                                nanoseconds: self.initialLoadRetryDelayNanoseconds
                            )
                        } catch {
                            return
                        }
                        continue
                    }

                    self.publishInitialLoadFailure(failure)
                    return
                }
            }
        }
    }

    private func loadInitialWindowAttempt() async -> Result<InitialWindowLoad, InitialLoadAttemptFailure> {
        do {
            let expectedDatasetGeneration = messageDatasetGeneration
            var preferPendingConversationMessages =
                initialWindowPosition == .end && hasPendingInsertedMessagesInConversation
            var initialRange = try await initialMessageRangeForInitialLoad(
                preferPendingConversationMessages: preferPendingConversationMessages
            )
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll initial load request conv=\(conversationId) range=\(initialRange.lowerBound)..<\(initialRange.upperBound)",
                category: .ui
            )
            var page = try await validatedInitialLoadPage(
                initialRange,
                preferPendingConversationMessages: preferPendingConversationMessages
            )

            guard !Task.isCancelled else {
                return .failure(.cancelled)
            }

            var remainingEndWindowRebaseAttempts = 2
            while true {
                guard !Task.isCancelled else {
                    return .failure(.cancelled)
                }
                guard expectedDatasetGeneration == messageDatasetGeneration else {
                    throw InitialLoadAttemptFailure.datasetChanged(
                        reportedTotalCount: page.totalCount
                    )
                }

                if shouldReloadInitialEndWindowForPendingLocalMessages(
                    preferredPendingMessages: preferPendingConversationMessages
                ) {
                    preferPendingConversationMessages = true
                    initialRange = try await initialMessageRangeForInitialLoad(
                        preferPendingConversationMessages: true
                    )
                    Log.diagnostic(
                        .chatView,
                        level: .info,
                        "VirtualScroll initial load switching to pending local messages conv=\(conversationId) range=\(initialRange.lowerBound)..<\(initialRange.upperBound)",
                        category: .ui
                    )
                    page = try await validatedInitialLoadPage(
                        initialRange,
                        preferPendingConversationMessages: true
                    )
                    continue
                }

                guard initialWindowPosition == .end,
                      page.totalCount != initialRange.upperBound else {
                    break
                }
                guard remainingEndWindowRebaseAttempts > 0 else {
                    throw InitialLoadAttemptFailure.inconsistentWindow(
                        totalCount: page.totalCount,
                        requestedIDCount: page.messageIDs.count,
                        resolvedRowCount: 0
                    )
                }

                remainingEndWindowRebaseAttempts -= 1
                let rebasedStartIndex = max(
                    0,
                    page.totalCount - configuration.visibleItemCount
                )
                initialRange = rebasedStartIndex..<page.totalCount
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "VirtualScroll initial latest-window count drift conv=\(conversationId) observedTotal=\(page.totalCount); rebasing to \(initialRange.lowerBound)..<\(initialRange.upperBound)",
                    category: .ui
                )
                page = try await validatedInitialLoadPage(
                    initialRange,
                    preferPendingConversationMessages: preferPendingConversationMessages
                )
            }

            if page.totalCount > 0 && page.messageIDs.isEmpty {
                throw InitialLoadAttemptFailure.inconsistentWindow(
                    totalCount: page.totalCount,
                    requestedIDCount: 0,
                    resolvedRowCount: 0
                )
            }
            let expectedIDCount = expectedMessageIDCount(
                in: initialRange,
                totalCount: page.totalCount
            )
            guard page.messageIDs.count == expectedIDCount else {
                throw InitialLoadAttemptFailure.inconsistentWindow(
                    totalCount: page.totalCount,
                    requestedIDCount: page.messageIDs.count,
                    resolvedRowCount: 0
                )
            }

            let messages: [ChatMessageRowModel]
            do {
                messages = try resolveRowsOnViewContextThrowing(for: page.messageIDs)
            } catch {
                throw InitialLoadAttemptFailure.rowFetchFailed(
                    description: error.localizedDescription,
                    reportedTotalCount: page.totalCount
                )
            }

            guard !Task.isCancelled else {
                return .failure(.cancelled)
            }
            guard expectedDatasetGeneration == messageDatasetGeneration else {
                throw InitialLoadAttemptFailure.datasetChanged(
                    reportedTotalCount: page.totalCount
                )
            }

            guard messages.count == page.messageIDs.count else {
                throw InitialLoadAttemptFailure.inconsistentWindow(
                    totalCount: page.totalCount,
                    requestedIDCount: page.messageIDs.count,
                    resolvedRowCount: messages.count
                )
            }

            let loadedRange = page.totalCount == 0 ? 0..<0 : initialRange
            return .success(
                InitialWindowLoad(
                    range: loadedRange,
                    page: page,
                    messages: messages
                )
            )
        } catch let failure as InitialLoadAttemptFailure {
            return .failure(failure)
        } catch {
            return .failure(
                .pageFetchFailed(
                    description: error.localizedDescription,
                    reportedTotalCount: nil
                )
            )
        }
    }

    private func initialMessageRangeForInitialLoad(
        preferPendingConversationMessages: Bool
    ) async throws -> Range<Int> {
        switch initialWindowPosition {
        case .beginning:
            return 0..<configuration.visibleItemCount
        case .end:
            let metadataPage = try await validatedInitialLoadPage(
                0..<0,
                preferPendingConversationMessages: preferPendingConversationMessages
            )
            let startIndex = max(0, metadataPage.totalCount - configuration.visibleItemCount)
            return startIndex..<metadataPage.totalCount
        }
    }

    private func validatedInitialLoadPage(
        _ range: Range<Int>,
        preferPendingConversationMessages: Bool
    ) async throws -> VirtualScrollMessagePage {
        let page = await loadPage(
            range,
            preferPendingConversationMessages: preferPendingConversationMessages
        )

        if let fetchErrorDescription = page.fetchErrorDescription {
            throw InitialLoadAttemptFailure.pageFetchFailed(
                description: fetchErrorDescription,
                reportedTotalCount: page.totalCount
            )
        }

        return page
    }

    private func publishInitialWindow(_ loadedWindow: InitialWindowLoad) {
        // A window load begun while this initial load was in flight (a reply
        // sent under the loading overlay) owns the lifecycle and the
        // transcript now: publishing this stale snapshot over it would
        // overwrite newer rows, arm an initial-anchor hold no view seam
        // would ever release, and regress the published count and phase.
        // Drop the superseded publish wholesale; the owning load's own
        // publish (or failure terminal) drives the phase from here. One
        // rescue: an owner that terminated without ever advancing the phase
        // (cancelled mid-flight) must not strand the spinner — an idle
        // lifecycle with the phase still unresolved means nobody else will
        // publish, so this snapshot is better than nothing.
        let ownsInitialPublish = windowLoadLifecycle == .loadingInitialWindow ||
            (windowLoadLifecycle == .idle && !isInitialLoadComplete)
        guard ownsInitialPublish else {
            finishInitialLoadSignpost(outcome: "superseded")
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll initial publish superseded by a concurrent window load conv=\(conversationId)",
                category: .ui
            )
            return
        }
        let page = loadedWindow.page
        let endIndex = loadedWindow.range.lowerBound + page.messageIDs.count
        let window = MessageWindow(
            startIndex: loadedWindow.range.lowerBound,
            endIndex: endIndex,
            messageIDs: page.messageIDs,
            isLoading: false
        )

        totalMessageCount = page.totalCount
        scrollPosition = loadedWindow.range.lowerBound
        // End-anchored windows hold onAppear-driven position updates until the
        // coordinator's reveal completes; see `isInitialAnchorHoldActive`.
        isInitialAnchorHoldActive =
            initialWindowPosition == .end && !loadedWindow.messages.isEmpty
        setMessageWindow(window)
        visibleMessages = loadedWindow.messages
        windowLoadLifecycle = .idle
        needsDatasetReconciliationAfterCurrentLoad = false
        initialLoadFailureReason = nil
        initialLoadPhase = loadedWindow.messages.isEmpty ? .empty : .loaded
        if !loadedWindow.messages.isEmpty {
            ChatViewPerformanceSignposts.firstRowsResolved(
                conversationID: conversationId,
                count: loadedWindow.messages.count
            )
        }
        resolvePendingInsertedMessageEvents()
        finishInitialLoadSignpost(
            outcome: loadedWindow.messages.isEmpty ? "empty" : "loaded"
        )
        scheduleUnclassifiedRefreshCountReconciliationIfNeeded()
        schedulePostSyncDatasetReconciliationIfNeeded()
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll initial load complete conv=\(conversationId) requested=\(loadedWindow.range.lowerBound)..<\(loadedWindow.range.upperBound) loaded=\(page.messageIDs.count) total=\(page.totalCount) window=\(window.startIndex)..<\(window.endIndex)",
            category: .ui
        )
    }

    private func publishInitialLoadFailure(_ failure: InitialLoadAttemptFailure) {
        // See publishInitialWindow: a concurrent window load owns the
        // lifecycle, phase, and count now. Reporting this stale failure
        // would flip a live transcript behind the failure overlay (phase
        // .failed over the .loaded that load published) and end a lifecycle
        // it does not own. Same rescue: if the owner retired without
        // resolving the phase, report the failure rather than strand the
        // spinner with no Try Again.
        let ownsFailurePublish = windowLoadLifecycle == .loadingInitialWindow ||
            (windowLoadLifecycle == .idle && !isInitialLoadComplete)
        guard ownsFailurePublish else {
            finishInitialLoadSignpost(outcome: "superseded")
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll initial load failure superseded by a concurrent window load conv=\(conversationId) reason=\(failure.diagnosticDescription)",
                category: .ui
            )
            return
        }
        if let reportedTotalCount = failure.reportedTotalCount {
            totalMessageCount = reportedTotalCount
        }
        windowLoadLifecycle = .idle
        initialLoadFailureReason = failure.userFacingReason
        initialLoadPhase = .failed
        finishInitialLoadSignpost(outcome: "failed")
        Log.diagnostic(
            .chatView,
            level: .error,
            "VirtualScroll initial load failed conv=\(conversationId) reason=\(failure.diagnosticDescription)",
            category: .ui
        )
    }
}

private extension VirtualScrollState.InitialWindowPosition {
    var diagnosticName: String {
        switch self {
        case .beginning:
            return "beginning"
        case .end:
            return "end"
        }
    }
}
