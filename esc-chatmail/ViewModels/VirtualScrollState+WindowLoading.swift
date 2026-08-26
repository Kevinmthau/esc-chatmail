import SwiftUI
import CoreData
import Combine

// MARK: - Window loading, latest-window follow, and preload pagination

extension VirtualScrollState {
    @discardableResult
    func loadLatestWindowIfNeeded(knownTotalCount: Int? = nil) async -> Bool {
        let knownCountIsAhead = knownTotalCount.map { $0 > totalMessageCount } ?? false
        guard knownCountIsAhead ||
            !isShowingLatestWindow ||
            visibleMessages.isEmpty ||
            !pendingInsertedMessageEvents.isEmpty ||
            hasPendingInsertedMessagesInConversation else {
            return true
        }

        return await loadLatestWindow()
    }

    /// Ensures a specific, permanently identified message is published in the
    /// latest visible window before a caller performs message-targeted work such
    /// as post-send anchoring.
    @discardableResult
    func ensureVisibleMessage(_ objectID: NSManagedObjectID) async -> Bool {
        guard !objectID.isTemporaryID else { return false }

        return await ensureVisibleMessage(
            objectID,
            retryAttemptsRemaining: maximumExplicitMessageVisibilityRetryCount
        )
    }

    private func ensureVisibleMessage(
        _ objectID: NSManagedObjectID,
        retryAttemptsRemaining: Int
    ) async -> Bool {
        if visibleMessages.contains(where: { $0.objectID == objectID }) {
            return true
        }

        // This is an explicit local-send reconciliation, so it intentionally
        // carries no follow-intent revision. User scroll takeover may suppress
        // automatic latest following, but must not suppress publishing the
        // optimistic row itself. Force the view-context path so unsaved pending
        // inserts are included.
        _ = await loadLatestWindow(forceViewContext: true)

        if visibleMessages.contains(where: { $0.objectID == objectID }) {
            return true
        }

        guard !Task.isCancelled, retryAttemptsRemaining > 0 else {
            return false
        }

        // A competing dataset reconciliation can supersede a window generation.
        // Yield once before the single bounded retry so that work can publish.
        await Task.yield()
        return await ensureVisibleMessage(
            objectID,
            retryAttemptsRemaining: retryAttemptsRemaining - 1
        )
    }

    @discardableResult
    func loadLatestWindow(
        forceViewContext: Bool = false,
        datasetRetryAttemptsRemaining: Int = 1,
        requiredFollowIntentRevision: UInt? = nil
    ) async -> Bool {
        guard isCurrentFollowIntent(requiredFollowIntentRevision) else {
            return false
        }
        if visibleMessages.isEmpty &&
            (initialLoadPhase == .empty || initialLoadPhase == .failed) {
            initialLoadFailureReason = nil
            initialLoadPhase = .loading
        }
        let preferPendingConversationMessages =
            forceViewContext || hasPendingInsertedMessagesInConversation
        // Captured before the load: when the current window already abuts the
        // tail, a latest reload must extend it rather than collapse it to the
        // last `visibleItemCount` rows. Collapsing dropped every row above the
        // viewport after a send, and the subsequent lazy re-expansion prepends
        // shifted the visible content onto older messages once the post-send
        // corrective scrolls had already fired. The window abuts the tail when
        // no rows exist beyond it, or when every row beyond it is a pending
        // tail insertion (the local-send case: the count was already bumped
        // for rows the window hasn't published yet). A historical window keeps
        // the collapse behavior so an explicit jump-to-latest stays cheap.
        let preservedWindowStartIndex = tailAbuttingWindowStartIndex()
        let loadGeneration = beginWindowLoad(
            intent: .latest(
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
        )
        let expectedDatasetGeneration = messageDatasetGeneration
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll latest window load start conv=\(conversationId) preferPending=\(preferPendingConversationMessages)",
            category: .ui
        )
        let loadedTotalCount = await loadTotalMessageCount(
            preferPendingConversationMessages: preferPendingConversationMessages
        )
        guard !Task.isCancelled else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return false
        }
        guard isCurrentFollowIntent(requiredFollowIntentRevision) else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return false
        }
        guard loadGeneration == windowLoadGeneration else { return false }
        guard expectedDatasetGeneration == messageDatasetGeneration else {
            guard datasetRetryAttemptsRemaining > 0 else {
                finishWindowLoadFailure(
                    operation: "latest window metadata",
                    description: "message dataset kept changing while loading"
                )
                return false
            }
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll latest metadata changed during load; retrying conv=\(conversationId)",
                category: .ui
            )
            return await loadLatestWindow(
                forceViewContext: forceViewContext,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining - 1,
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
        }
        guard let totalCount = loadedTotalCount else {
            finishWindowLoadFailure(
                operation: "latest window metadata",
                description: "unable to fetch message count"
            )
            return false
        }
        let collapsedStartIndex = max(0, totalCount - configuration.visibleItemCount)
        let startIndex: Int
        if let preservedWindowStartIndex {
            // Keep the accumulated rows above the viewport, bounded by the
            // window cap so long sessions do not grow without limit.
            let cappedStartIndex = max(0, totalCount - configuration.maxWindowSize)
            startIndex = max(min(preservedWindowStartIndex, collapsedStartIndex), cappedStartIndex)
        } else {
            startIndex = collapsedStartIndex
        }
        guard let loadedBounds = await loadWindow(
            startIndex: startIndex,
            endIndex: totalCount,
            preferPendingConversationMessages: preferPendingConversationMessages,
            latestRebaseAttemptsRemaining: 2,
            generation: loadGeneration,
            datasetGeneration: expectedDatasetGeneration,
            datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining,
            requiredFollowIntentRevision: requiredFollowIntentRevision
        ) else {
            return false
        }
        guard loadedBounds.generation == windowLoadGeneration else { return false }
        if isCurrentFollowIntent(requiredFollowIntentRevision) {
            // Mirror publishInitialWindow: anchor the tracked position at the
            // window head. Parking it at the tail made the window-head row's
            // onAppear pass markIndexVisible's movement guard, which requested
            // an older range the fresh window didn't cover and cascaded
            // prepends that shifted the viewport onto older messages.
            scrollPosition = loadedBounds.startIndex
        }
        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll latest window load complete conv=\(conversationId) total=\(loadedBounds.totalCount) window=\(loadedBounds.startIndex)..<\(loadedBounds.totalCount)",
            category: .ui
        )
        return true
    }

    /// The current window's start index when the window abuts the dataset
    /// tail, nil otherwise. Rows beyond the window's end only count as "tail"
    /// when they are pending tail insertions the window hasn't published yet.
    private func tailAbuttingWindowStartIndex() -> Int? {
        guard let window = messageWindow else { return nil }

        let tailGap = totalMessageCount - window.endIndex
        if tailGap <= 0 {
            return window.startIndex
        }

        var pendingInsertedIDs = Set(pendingInsertedMessageEvents.flatMap(\.messageIDs))
        if let conversationUUID = UUID(uuidString: conversationId) {
            for object in viewContext.insertedObjects {
                guard let message = object as? Message,
                      message.conversation?.id == conversationUUID else { continue }
                pendingInsertedIDs.insert(message.objectID)
            }
        }
        pendingInsertedIDs.subtract(window.messageIDs)
        return tailGap <= pendingInsertedIDs.count ? window.startIndex : nil
    }

    private func retryWindowAfterDatasetChange(
        startIndex: Int,
        endIndex: Int,
        preferPendingConversationMessages: Bool,
        latestRebaseAttemptsRemaining: Int?,
        rangeClampAttemptsRemaining: Int,
        generation: UInt,
        datasetRetryAttemptsRemaining: Int,
        requiredFollowIntentRevision: UInt?,
        operation: String
    ) async -> LoadedWindowBounds? {
        guard datasetRetryAttemptsRemaining > 0 else {
            finishWindowLoadFailure(
                operation: operation,
                description: "message dataset kept changing while loading"
            )
            return nil
        }

        Log.diagnostic(
            .chatView,
            level: .info,
            "VirtualScroll \(operation) dataset changed; retrying conv=\(conversationId)",
            category: .ui
        )
        return await loadWindow(
            startIndex: startIndex,
            endIndex: endIndex,
            preferPendingConversationMessages:
                preferPendingConversationMessages || hasPendingInsertedMessagesInConversation,
            latestRebaseAttemptsRemaining: latestRebaseAttemptsRemaining,
            rangeClampAttemptsRemaining: rangeClampAttemptsRemaining,
            generation: generation,
            datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining - 1,
            requiredFollowIntentRevision: requiredFollowIntentRevision
        )
    }

    func updateVisibleMessages() {
        guard let window = messageWindow else { return }

        let startIndex = max(0, scrollPosition - configuration.bufferSize)
        let endIndex = min(totalMessageCount, scrollPosition + configuration.visibleItemCount + configuration.bufferSize)

        if window.contains(index: startIndex) && window.contains(index: endIndex - 1) {
            // Current window already covers the requested range.
            // Keep rendering the whole window so the user can continue scrolling
            // through the buffered messages without the view pruning rows away.
            visibleMessages = resolveCachedRows(for: window.messageIDs)
        } else {
            // Need to load a new window.
            let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation
            taskManager.run("loadWindow") { [weak self] in
                guard let self = self else { return }
                _ = await self.loadWindow(
                    startIndex: startIndex,
                    endIndex: endIndex,
                    preferPendingConversationMessages: preferPendingConversationMessages
                )
            }
        }
    }

    func loadWindow(
        startIndex: Int,
        endIndex: Int,
        preferPendingConversationMessages: Bool = false,
        latestRebaseAttemptsRemaining: Int? = nil,
        rangeClampAttemptsRemaining: Int = 1,
        generation: UInt? = nil,
        datasetGeneration: UInt? = nil,
        datasetRetryAttemptsRemaining: Int = 1,
        requiredFollowIntentRevision: UInt? = nil
    ) async -> LoadedWindowBounds? {
        guard startIndex >= 0, endIndex >= startIndex else {
            return nil
        }
        guard isCurrentFollowIntent(requiredFollowIntentRevision) else {
            if let generation {
                finishCancelledWindowLoad(generation: generation)
            }
            return nil
        }

        let loadGeneration = generation ?? beginWindowLoad(
            intent: .range(startIndex..<endIndex)
        )
        let expectedDatasetGeneration = datasetGeneration ?? messageDatasetGeneration
        guard loadGeneration == windowLoadGeneration else { return nil }

        let page = await loadPage(
            startIndex..<endIndex,
            preferPendingConversationMessages: preferPendingConversationMessages
        )

        guard !Task.isCancelled else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return nil
        }
        guard isCurrentFollowIntent(requiredFollowIntentRevision) else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return nil
        }
        guard loadGeneration == windowLoadGeneration else {
            return nil
        }
        guard expectedDatasetGeneration == messageDatasetGeneration else {
            return await retryWindowAfterDatasetChange(
                startIndex: startIndex,
                endIndex: endIndex,
                preferPendingConversationMessages: preferPendingConversationMessages,
                latestRebaseAttemptsRemaining: latestRebaseAttemptsRemaining,
                rangeClampAttemptsRemaining: rangeClampAttemptsRemaining,
                generation: loadGeneration,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining,
                requiredFollowIntentRevision: requiredFollowIntentRevision,
                operation: "window"
            )
        }

        guard page.fetchErrorDescription == nil else {
            finishWindowLoadFailure(
                operation: "window",
                description: page.fetchErrorDescription ?? "Unknown fetch error"
            )
            return nil
        }

        if let latestRebaseAttemptsRemaining, page.totalCount != endIndex {
            guard latestRebaseAttemptsRemaining > 0 else {
                finishWindowLoadFailure(
                    operation: "latest window",
                    description: "message count kept changing while rebasing"
                )
                return nil
            }
            let rebasedStartIndex = max(
                0,
                page.totalCount - configuration.visibleItemCount
            )
            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll latest window count drift conv=\(conversationId) requested=\(startIndex)..<\(endIndex) observedTotal=\(page.totalCount); rebasing",
                category: .ui
            )
            return await loadWindow(
                startIndex: rebasedStartIndex,
                endIndex: page.totalCount,
                preferPendingConversationMessages: preferPendingConversationMessages,
                latestRebaseAttemptsRemaining: latestRebaseAttemptsRemaining - 1,
                rangeClampAttemptsRemaining: rangeClampAttemptsRemaining,
                generation: loadGeneration,
                datasetGeneration: expectedDatasetGeneration,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining,
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
        }

        if latestRebaseAttemptsRemaining == nil,
           page.totalCount > 0,
           endIndex > page.totalCount,
           rangeClampAttemptsRemaining > 0 {
            let desiredWindowCount = max(1, endIndex - startIndex)
            let latestPossibleStart = max(0, page.totalCount - desiredWindowCount)
            let adjustedStartIndex = min(startIndex, latestPossibleStart)
            let adjustedEndIndex = min(
                page.totalCount,
                adjustedStartIndex + desiredWindowCount
            )

            Log.diagnostic(
                .chatView,
                level: .info,
                "VirtualScroll window count drift conv=\(conversationId) requested=\(startIndex)..<\(endIndex) observedTotal=\(page.totalCount); clamping to \(adjustedStartIndex)..<\(adjustedEndIndex)",
                category: .ui
            )
            return await loadWindow(
                startIndex: adjustedStartIndex,
                endIndex: adjustedEndIndex,
                preferPendingConversationMessages: preferPendingConversationMessages,
                rangeClampAttemptsRemaining: rangeClampAttemptsRemaining - 1,
                generation: loadGeneration,
                datasetGeneration: expectedDatasetGeneration,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining,
                requiredFollowIntentRevision: requiredFollowIntentRevision
            )
        }

        let expectedIDCount = expectedMessageIDCount(
            in: startIndex..<endIndex,
            totalCount: page.totalCount
        )
        guard page.totalCount == 0 || expectedIDCount > 0 else {
            finishWindowLoadFailure(
                operation: "window",
                description: "range \(startIndex)..<\(endIndex) is outside observed total \(page.totalCount)"
            )
            return nil
        }
        guard page.messageIDs.count == expectedIDCount else {
            finishWindowLoadFailure(
                operation: "window",
                description: "received \(page.messageIDs.count) IDs, expected \(expectedIDCount), for range \(startIndex)..<\(endIndex) with total \(page.totalCount)"
            )
            return nil
        }

        let messages: [ChatMessageRowModel]
        do {
            messages = try resolveRowsOnViewContextThrowing(for: page.messageIDs)
        } catch {
            finishWindowLoadFailure(
                operation: "window row resolution",
                description: error.localizedDescription
            )
            return nil
        }

        guard !Task.isCancelled else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return nil
        }
        guard loadGeneration == windowLoadGeneration else {
            return nil
        }
        guard expectedDatasetGeneration == messageDatasetGeneration else {
            return await retryWindowAfterDatasetChange(
                startIndex: startIndex,
                endIndex: endIndex,
                preferPendingConversationMessages: preferPendingConversationMessages,
                latestRebaseAttemptsRemaining: latestRebaseAttemptsRemaining,
                rangeClampAttemptsRemaining: rangeClampAttemptsRemaining,
                generation: loadGeneration,
                datasetRetryAttemptsRemaining: datasetRetryAttemptsRemaining,
                requiredFollowIntentRevision: requiredFollowIntentRevision,
                operation: "window row resolution"
            )
        }
        guard messages.count == page.messageIDs.count else {
            finishWindowLoadFailure(
                operation: "window row resolution",
                description: "resolved \(messages.count) of \(page.messageIDs.count) rows"
            )
            return nil
        }
        guard isCurrentFollowIntent(requiredFollowIntentRevision) else {
            finishCancelledWindowLoad(generation: loadGeneration)
            return nil
        }

        let publishedStartIndex = page.totalCount == 0 ? 0 : startIndex
        let loadedEndIndex = publishedStartIndex + page.messageIDs.count
        let window = MessageWindow(
            startIndex: publishedStartIndex,
            endIndex: loadedEndIndex,
            messageIDs: page.messageIDs,
            isLoading: false
        )

        totalMessageCount = page.totalCount
        setMessageWindow(window)
        visibleMessages = messages
        windowLoadLifecycle = .idle
        updateAvailabilityPhaseAfterWindowLoad(page: page, messages: messages)
        needsDatasetReconciliationAfterCurrentLoad = false
        resolvePendingInsertedMessageEvents()
        scheduleUnclassifiedRefreshCountReconciliationIfNeeded()
        schedulePostSyncDatasetReconciliationIfNeeded()
        return LoadedWindowBounds(
            startIndex: publishedStartIndex,
            totalCount: page.totalCount,
            generation: loadGeneration
        )
    }

    func loadTotalMessageCount(
        preferPendingConversationMessages: Bool = false
    ) async -> Int? {
        let metadataPage = await loadPage(
            0..<0,
            preferPendingConversationMessages: preferPendingConversationMessages
        )

        if let fetchErrorDescription = metadataPage.fetchErrorDescription {
            Log.diagnostic(
                .chatView,
                level: .error,
                "VirtualScroll metadata load failed conv=\(conversationId) error=\(fetchErrorDescription)",
                category: .ui
            )
            return nil
        }

        return metadataPage.totalCount
    }

    func shouldReloadInitialEndWindowForPendingLocalMessages(
        preferredPendingMessages: Bool
    ) -> Bool {
        initialWindowPosition == .end &&
            !preferredPendingMessages &&
            hasPendingInsertedMessagesInConversation
    }

    func loadPage(
        _ range: Range<Int>,
        preferPendingConversationMessages: Bool = false
    ) async -> VirtualScrollMessagePage {
        if preferPendingConversationMessages {
            return await Self.loadPendingMessagePage(
                conversationId: conversationId,
                range: range,
                in: viewContext
            )
        }

        return await pageLoader(conversationId, range, makeBackgroundContext())
    }

    func preloadIfNeeded() {
        guard let window = messageWindow else { return }

        let distanceToEnd = window.endIndex - scrollPosition
        if distanceToEnd < configuration.preloadThreshold {
            preloadNext()
        }

        let distanceToStart = scrollPosition - window.startIndex
        if distanceToStart < configuration.preloadThreshold {
            preloadPrevious()
        }
    }

    func preloadNext() {
        guard let window = messageWindow,
              window.endIndex < totalMessageCount else { return }

        let startIndex = window.endIndex
        let endIndex = min(totalMessageCount, startIndex + configuration.pageSize)
        let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation
        let expectedTotalCount = totalMessageCount
        let expectedDatasetGeneration = messageDatasetGeneration

        taskManager.run("preloadNext") { [weak self] in
            guard let self = self else { return }

            let page = await self.loadPage(
                startIndex..<endIndex,
                preferPendingConversationMessages: preferPendingConversationMessages
            )

            guard !Task.isCancelled else { return }
            guard page.fetchErrorDescription == nil else {
                self.logPreloadFailure(
                    direction: "next",
                    description: page.fetchErrorDescription ?? "Unknown fetch error"
                )
                return
            }
            guard self.messageDatasetGeneration == expectedDatasetGeneration,
                  page.totalCount == expectedTotalCount else {
                self.logPreloadFailure(
                    direction: "next",
                    description: "message dataset changed while loading"
                )
                return
            }
            guard Set(page.messageIDs).isDisjoint(with: window.messageIDs) else {
                self.logPreloadFailure(
                    direction: "next",
                    description: "page overlapped the captured window"
                )
                return
            }
            let expectedIDCount = self.expectedMessageIDCount(
                in: startIndex..<endIndex,
                totalCount: page.totalCount
            )
            guard expectedIDCount > 0, page.messageIDs.count == expectedIDCount else {
                self.logPreloadFailure(
                    direction: "next",
                    description: "received \(page.messageIDs.count) IDs, expected \(expectedIDCount), for range \(startIndex)..<\(endIndex) with total \(page.totalCount)"
                )
                return
            }

            let messages: [ChatMessageRowModel]
            do {
                messages = try self.resolveRowsOnViewContextThrowing(for: page.messageIDs)
            } catch {
                self.logPreloadFailure(
                    direction: "next",
                    description: error.localizedDescription
                )
                return
            }

            guard !Task.isCancelled else { return }
            guard messages.count == page.messageIDs.count else {
                self.logPreloadFailure(
                    direction: "next",
                    description: "resolved \(messages.count) of \(page.messageIDs.count) rows"
                )
                return
            }

            guard var currentWindow = self.messageWindow,
                  currentWindow.startIndex == window.startIndex,
                  currentWindow.endIndex == window.endIndex,
                  currentWindow.messageIDs == window.messageIDs else {
                return
            }

            currentWindow.messageIDs.append(contentsOf: page.messageIDs)
            currentWindow = MessageWindow(
                startIndex: currentWindow.startIndex,
                endIndex: startIndex + page.messageIDs.count,
                messageIDs: currentWindow.messageIDs,
                isLoading: false
            ).frontTrimmed(to: self.configuration.maxWindowSize)

            self.totalMessageCount = page.totalCount
            self.setMessageWindow(currentWindow)
            self.visibleMessages = self.resolveCachedRows(for: currentWindow.messageIDs)
            self.schedulePostSyncDatasetReconciliationIfNeeded()
        }
    }

    private func preloadPrevious() {
        guard let window = messageWindow,
              window.startIndex > 0 else { return }

        let endIndex = window.startIndex
        let startIndex = max(0, endIndex - configuration.pageSize)
        let preferPendingConversationMessages = hasPendingInsertedMessagesInConversation
        let expectedTotalCount = totalMessageCount
        let expectedDatasetGeneration = messageDatasetGeneration

        taskManager.run("preloadPrevious") { [weak self] in
            guard let self = self else { return }

            let page = await self.loadPage(
                startIndex..<endIndex,
                preferPendingConversationMessages: preferPendingConversationMessages
            )

            guard !Task.isCancelled else { return }
            guard page.fetchErrorDescription == nil else {
                self.logPreloadFailure(
                    direction: "previous",
                    description: page.fetchErrorDescription ?? "Unknown fetch error"
                )
                return
            }
            guard self.messageDatasetGeneration == expectedDatasetGeneration,
                  page.totalCount == expectedTotalCount else {
                self.logPreloadFailure(
                    direction: "previous",
                    description: "message dataset changed while loading"
                )
                return
            }
            guard Set(page.messageIDs).isDisjoint(with: window.messageIDs) else {
                self.logPreloadFailure(
                    direction: "previous",
                    description: "page overlapped the captured window"
                )
                return
            }
            let expectedIDCount = self.expectedMessageIDCount(
                in: startIndex..<endIndex,
                totalCount: page.totalCount
            )
            guard expectedIDCount > 0, page.messageIDs.count == expectedIDCount else {
                self.logPreloadFailure(
                    direction: "previous",
                    description: "received \(page.messageIDs.count) IDs, expected \(expectedIDCount), for range \(startIndex)..<\(endIndex) with total \(page.totalCount)"
                )
                return
            }

            let messages: [ChatMessageRowModel]
            do {
                messages = try self.resolveRowsOnViewContextThrowing(for: page.messageIDs)
            } catch {
                self.logPreloadFailure(
                    direction: "previous",
                    description: error.localizedDescription
                )
                return
            }

            guard !Task.isCancelled else { return }
            guard messages.count == page.messageIDs.count else {
                self.logPreloadFailure(
                    direction: "previous",
                    description: "resolved \(messages.count) of \(page.messageIDs.count) rows"
                )
                return
            }

            guard var currentWindow = self.messageWindow,
                  currentWindow.startIndex == window.startIndex,
                  currentWindow.endIndex == window.endIndex,
                  currentWindow.messageIDs == window.messageIDs else {
                return
            }

            currentWindow.messageIDs = page.messageIDs + currentWindow.messageIDs

            // Back-trim against the window cap: the user is scrolling UP, so
            // the trimmed rows are far below the viewport and their removal
            // cannot shift visible content.
            currentWindow = MessageWindow(
                startIndex: startIndex,
                endIndex: currentWindow.endIndex,
                messageIDs: currentWindow.messageIDs,
                isLoading: false
            ).backTrimmed(to: self.configuration.maxWindowSize)

            self.totalMessageCount = page.totalCount
            self.setMessageWindow(currentWindow)
            self.visibleMessages = self.resolveCachedRows(for: currentWindow.messageIDs)
            self.schedulePostSyncDatasetReconciliationIfNeeded()
        }
    }
}
