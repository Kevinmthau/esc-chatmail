import Foundation
import CoreData
import CoreGraphics
import Combine

@MainActor
final class ChatMessagesCoordinator: ObservableObject {
    private enum TaskKey {
        static let bottomAnchor = "bottomAnchor"
        static let initialBottomAnchor = "initialBottomAnchor"
        static let latestWindow = "latestWindow"
    }

    struct BottomAnchorStep: Equatable {
        let delay: TimeInterval
        let animated: Bool
        let logMessage: String
        var marksReady: Bool = false
    }

    typealias BottomAnchorAction = @MainActor (BottomAnchorStep) -> Void
    typealias SenderGroupingLoader = ([String]) async -> [String: String]
    typealias AsyncAction = () async -> Void
    typealias LatestWindowLoader = (Int?) async -> Void
    typealias Sleep = (UInt64) async -> Void

    @Published private(set) var isReadyToShow = false
    @Published private(set) var contactRefreshToken = 0
    @Published private(set) var senderGroupingKeysByEmail: [String: String] = [:]

    private let loadLatestWindowIfNeeded: LatestWindowLoader
    private let markConversationAsReadIfNeeded: () -> Void
    private let markUnreadInboxMessagesAsReadIfNeeded: ([NSManagedObjectID]) -> Void
    private let initializeReplyingTo: (Message?) -> Void
    private let updateReplyingToIfNewSubject: (Message?) -> Void
    private let loadResolvedDisplayName: () -> Void
    private let prefetchRecentContent: ([String], [String]) -> Void
    private let cancelPrefetch: () -> Void
    private let loadSenderGroupingKeys: SenderGroupingLoader
    private let invalidateContactsCache: AsyncAction
    private let clearPersonCache: AsyncAction
    private let sleep: Sleep
    private let taskManager = ViewModelTaskManager()
    private var hasStartedInitialAnchor = false
    private var initialAnchorWasForEmptyConversation = false
    private var hasCapturedInitialUnreadSnapshot = false
    private var isVisible = false

    init(
        scrollState: VirtualScrollState,
        viewModel: ChatViewModel,
        chatDependencies: ChatDependencies,
        sleep: @escaping Sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.loadLatestWindowIfNeeded = { knownTotalCount in
            await scrollState.loadLatestWindowIfNeeded(knownTotalCount: knownTotalCount)
        }
        self.markConversationAsReadIfNeeded = {
            viewModel.markConversationAsReadIfNeeded()
        }
        self.markUnreadInboxMessagesAsReadIfNeeded = { messageObjectIDs in
            viewModel.markUnreadInboxMessagesAsReadIfNeeded(messageObjectIDs: messageObjectIDs)
        }
        self.initializeReplyingTo = { lastMessage in
            viewModel.initializeReplyingTo(lastMessage: lastMessage)
        }
        self.updateReplyingToIfNewSubject = { lastMessage in
            viewModel.updateReplyingToIfNewSubject(lastMessage: lastMessage)
        }
        self.loadResolvedDisplayName = {
            viewModel.loadResolvedDisplayName()
        }
        self.prefetchRecentContent = { messageIds, senderEmails in
            viewModel.prefetchRecentContent(messageIds: messageIds, senderEmails: senderEmails)
        }
        self.cancelPrefetch = {
            viewModel.cancelPrefetch()
        }
        self.loadSenderGroupingKeys = { senderEmails in
            await chatDependencies.contacts.participantLoader.senderGroupingKeys(for: senderEmails)
        }
        self.invalidateContactsCache = chatDependencies.contacts.invalidateContactsCache
        self.clearPersonCache = chatDependencies.contacts.clearPersonCache
        self.sleep = sleep
    }

    init(
        loadLatestWindowIfNeeded: @escaping LatestWindowLoader,
        markConversationAsReadIfNeeded: @escaping () -> Void,
        markUnreadInboxMessagesAsReadIfNeeded: @escaping ([NSManagedObjectID]) -> Void = { _ in },
        initializeReplyingTo: @escaping (Message?) -> Void,
        updateReplyingToIfNewSubject: @escaping (Message?) -> Void,
        loadResolvedDisplayName: @escaping () -> Void,
        prefetchRecentContent: @escaping ([String], [String]) -> Void,
        cancelPrefetch: @escaping () -> Void,
        loadSenderGroupingKeys: @escaping SenderGroupingLoader,
        invalidateContactsCache: @escaping AsyncAction,
        clearPersonCache: @escaping AsyncAction,
        sleep: @escaping Sleep
    ) {
        self.loadLatestWindowIfNeeded = loadLatestWindowIfNeeded
        self.markConversationAsReadIfNeeded = markConversationAsReadIfNeeded
        self.markUnreadInboxMessagesAsReadIfNeeded = markUnreadInboxMessagesAsReadIfNeeded
        self.initializeReplyingTo = initializeReplyingTo
        self.updateReplyingToIfNewSubject = updateReplyingToIfNewSubject
        self.loadResolvedDisplayName = loadResolvedDisplayName
        self.prefetchRecentContent = prefetchRecentContent
        self.cancelPrefetch = cancelPrefetch
        self.loadSenderGroupingKeys = loadSenderGroupingKeys
        self.invalidateContactsCache = invalidateContactsCache
        self.clearPersonCache = clearPersonCache
        self.sleep = sleep
    }

    func handleAppear(
        messageCount: Int,
        lastMessage: Message?,
        visibleMessages: [ChatMessageRowModel],
        senderGroupingMessages: [ChatMessageRowModel],
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        isVisible = true
        if !hasCapturedInitialUnreadSnapshot {
            hasCapturedInitialUnreadSnapshot = true
            markConversationAsReadIfNeeded()
        }
        initializeReplyingTo(lastMessage)

        startInitialAnchorIfPossible(
            messageCount: messageCount,
            visibleMessages: visibleMessages,
            totalMessageCount: totalMessageCount,
            isInitialWindowLoaded: isInitialWindowLoaded,
            reason: "appear",
            scrollAction: scrollAction
        )

        loadResolvedDisplayName()
        prefetchVisibleContent(from: visibleMessages)
        refreshSenderGroupingKeys(using: senderGroupingMessages)
    }

    func handleInitialWindowLoaded(
        messageCount: Int,
        visibleMessages: [ChatMessageRowModel],
        senderGroupingMessages: [ChatMessageRowModel],
        totalMessageCount: Int,
        scrollAction: @escaping BottomAnchorAction
    ) {
        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView initial window loaded messages=\(messageCount) visible=\(visibleMessages.count) total=\(totalMessageCount)",
            category: .ui
        )
        startInitialAnchorIfPossible(
            messageCount: messageCount,
            visibleMessages: visibleMessages,
            totalMessageCount: totalMessageCount,
            isInitialWindowLoaded: true,
            reason: "initial-window-loaded",
            scrollAction: scrollAction
        )
        prefetchVisibleContent(from: visibleMessages)
        refreshSenderGroupingKeys(using: senderGroupingMessages)
    }

    func handleDisappear() {
        isVisible = false
        taskManager.cancelAll()
        cancelPrefetch()
        if !isReadyToShow {
            hasStartedInitialAnchor = false
            initialAnchorWasForEmptyConversation = false
        }
    }

    func handleDisplayedMessagesChange(
        oldIDs: [NSManagedObjectID],
        newIDs: [NSManagedObjectID],
        visibleMessages: [ChatMessageRowModel],
        senderGroupingMessages: [ChatMessageRowModel],
        messageCount: Int,
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        startInitialAnchorIfPossible(
            messageCount: messageCount,
            visibleMessages: visibleMessages,
            totalMessageCount: totalMessageCount,
            isInitialWindowLoaded: isInitialWindowLoaded,
            reason: "displayed-messages-change",
            scrollAction: scrollAction
        )

        if oldIDs != newIDs {
            prefetchVisibleContent(from: visibleMessages)
            refreshSenderGroupingKeys(using: senderGroupingMessages)
        }
    }

    func handleInsertedVisibleMessages(
        messageObjectIDs: [NSManagedObjectID],
        isChatActiveAndUncovered: Bool,
        isShowingLatestWindow: Bool,
        isBottomAnchorVisible: Bool
    ) {
        guard !messageObjectIDs.isEmpty,
              isReadyToShow,
              isVisible,
              isChatActiveAndUncovered,
              isShowingLatestWindow,
              isBottomAnchorVisible else {
            return
        }

        markUnreadInboxMessagesAsReadIfNeeded(messageObjectIDs)
    }

    func handleMessageCountChange(
        oldCount: Int,
        newCount: Int,
        lastMessage: Message?,
        visibleMessages: [ChatMessageRowModel],
        totalMessageCount: Int,
        stabilizeBottomAnchor: Bool,
        isInitialWindowLoaded: Bool,
        isShowingLatestWindow: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        if oldCount == 0 && newCount > 0 {
            updateReplyingToIfNewSubject(lastMessage)
            if hasStartedInitialAnchor && !initialAnchorWasForEmptyConversation {
                if isInitialWindowLoaded {
                    requestLatestWindowIfNeeded(knownTotalCount: newCount)
                }
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView empty-to-loaded count change refreshes latest window because initial anchoring already started messages=\(newCount)",
                    category: .ui
                )
            } else {
                isReadyToShow = false
                hasStartedInitialAnchor = false
                initialAnchorWasForEmptyConversation = false
                if isInitialWindowLoaded {
                    requestLatestWindowIfNeeded(knownTotalCount: newCount)
                }
                startInitialAnchorIfPossible(
                    messageCount: newCount,
                    visibleMessages: visibleMessages,
                    totalMessageCount: max(totalMessageCount, newCount),
                    isInitialWindowLoaded: isInitialWindowLoaded,
                    reason: "message-count-change",
                    scrollAction: scrollAction
                )
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView empty-to-loaded count change uses initial anchoring messages=\(newCount) initialWindowLoaded=\(isInitialWindowLoaded)",
                    category: .ui
                )
            }
        } else if !isInitialWindowLoaded {
            if newCount > oldCount {
                Log.diagnostic(
                    .chatView,
                    level: .info,
                    "ChatView deferring message-count bottom anchor until initial window loads old=\(oldCount) new=\(newCount)",
                    category: .ui
                )
            }
        } else if !isReadyToShow && newCount > 0 {
            if newCount > oldCount {
                requestLatestWindowIfNeeded(knownTotalCount: newCount)
            }
            startInitialAnchorIfPossible(
                messageCount: newCount,
                visibleMessages: visibleMessages,
                totalMessageCount: max(totalMessageCount, newCount),
                isInitialWindowLoaded: isInitialWindowLoaded,
                reason: "message-count-change",
                scrollAction: scrollAction
            )
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView handling count-change before initial reveal completes messages=\(newCount)",
                category: .ui
            )
        } else if isReadyToShow && newCount > oldCount && isShowingLatestWindow {
            updateReplyingToIfNewSubject(lastMessage)
            scrollToBottom(
                messageCount: newCount,
                delay: UIConfig.contentChangeScrollDelay,
                includeStabilizationStep: stabilizeBottomAnchor,
                knownTotalCount: newCount,
                scrollAction: scrollAction
            )
        }

        loadResolvedDisplayName()
    }

    func handleKeyboardHeightChange(
        oldHeight: CGFloat,
        newHeight: CGFloat,
        messageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard isInitialWindowLoaded, isReadyToShow else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView skipping keyboard bottom anchor before initial reveal loaded=\(isInitialWindowLoaded) ready=\(isReadyToShow)",
                category: .ui
            )
            return
        }

        if newHeight > 0 || (oldHeight > 0 && newHeight == 0) {
            scrollToBottom(
                messageCount: messageCount,
                delay: UIConfig.contentChangeScrollDelay,
                scrollAction: scrollAction
            )
        }
    }

    func handleTextFieldFocusChange(
        isFocused: Bool,
        messageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard isInitialWindowLoaded, isReadyToShow else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView skipping focus bottom anchor before initial reveal loaded=\(isInitialWindowLoaded) ready=\(isReadyToShow)",
                category: .ui
            )
            return
        }

        if !isFocused {
            scrollToBottom(
                messageCount: messageCount,
                delay: UIConfig.initialScrollDelay,
                scrollAction: scrollAction
            )
        }
    }

    func handleReplySendCompleted(
        messageCount: Int,
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard isInitialWindowLoaded else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView deferring post-send refresh until initial window loads messages=\(messageCount) total=\(totalMessageCount)",
                category: .ui
            )
            return
        }

        let anchorMessageCount = max(messageCount, totalMessageCount)
        guard anchorMessageCount > 0 else { return }

        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView post-send refresh requested messages=\(messageCount) total=\(totalMessageCount)",
            category: .ui
        )
        scrollToBottom(
            messageCount: anchorMessageCount,
            delay: UIConfig.contentChangeScrollDelay,
            includeStabilizationStep: true,
            knownTotalCount: anchorMessageCount,
            scrollAction: scrollAction
        )
    }

    func handleContactStoreDidChange(senderGroupingMessages: [ChatMessageRowModel]) {
        taskManager.run("contactRefresh") { [invalidateContactsCache, clearPersonCache] in
            await invalidateContactsCache()
            await clearPersonCache()

            guard !Task.isCancelled else { return }

            self.contactRefreshToken &+= 1
            self.loadResolvedDisplayName()
            self.refreshSenderGroupingKeys(using: senderGroupingMessages)
        }
    }

    func handlePersonDisplayInfoDidChange(senderGroupingMessages: [ChatMessageRowModel]) {
        contactRefreshToken &+= 1
        loadResolvedDisplayName()
        refreshSenderGroupingKeys(using: senderGroupingMessages)
    }

    func senderRunKey(
        for message: ChatMessageRowModel?,
        isEffectivelyOneToOneConversation: Bool
    ) -> String? {
        guard let message else { return nil }
        guard !message.isFromMe else { return "me" }
        guard let senderEmail = senderEmail(for: message) else { return "email:" }

        let normalizedEmail = EmailNormalizer.normalize(senderEmail)
        if isEffectivelyOneToOneConversation {
            return senderGroupingKeysByEmail[normalizedEmail] ?? "email:\(normalizedEmail)"
        }

        return "email:\(normalizedEmail)"
    }

    private func prefetchVisibleContent(from visibleMessages: [ChatMessageRowModel]) {
        let config = VirtualScrollConfiguration.default
        let prefetchLimit = config.visibleItemCount + config.bufferSize
        let recentMessages = visibleMessages.suffix(prefetchLimit)
        let messageIds = recentMessages
            .filter { message in
                message.chatPreviewText?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ?? true
            }
            .map(\.id)
        let senderEmails = recentMessages.compactMap(\.senderEmail)

        prefetchRecentContent(messageIds, senderEmails)
    }

    private func refreshSenderGroupingKeys(using visibleMessages: [ChatMessageRowModel]) {
        var uniqueSenderEmails: [String] = []
        var seenEmails = Set<String>()
        for message in visibleMessages {
            guard let email = senderEmail(for: message) else { continue }
            let normalizedEmail = EmailNormalizer.normalize(email)
            guard !normalizedEmail.isEmpty,
                  seenEmails.insert(normalizedEmail).inserted else {
                continue
            }
            uniqueSenderEmails.append(email)
        }

        taskManager.run("senderGrouping") { [loadSenderGroupingKeys] in
            let groupingKeys = await loadSenderGroupingKeys(uniqueSenderEmails)
            guard !Task.isCancelled else { return }
            self.senderGroupingKeysByEmail = groupingKeys
        }
    }

    private func senderEmail(for message: ChatMessageRowModel) -> String? {
        if let senderEmail = message.senderGroupingKeyInput?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !senderEmail.isEmpty {
            return senderEmail
        }

        return nil
    }

    private func startInitialAnchorIfPossible(
        messageCount: Int,
        visibleMessages: [ChatMessageRowModel],
        totalMessageCount: Int,
        isInitialWindowLoaded: Bool,
        reason: String,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard !isReadyToShow else { return }

        let anchorMessageCount = max(messageCount, totalMessageCount)

        guard anchorMessageCount > 0 else {
            hasStartedInitialAnchor = true
            initialAnchorWasForEmptyConversation = true
            isReadyToShow = true
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial anchor skipped for empty conversation reason=\(reason)",
                category: .ui
            )
            return
        }

        guard isInitialWindowLoaded else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial anchor deferred until virtual window loads reason=\(reason) messages=\(messageCount) visible=\(visibleMessages.count) total=\(totalMessageCount)",
                category: .ui
            )
            return
        }

        guard !visibleMessages.isEmpty else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial anchor waiting for visible rows reason=\(reason) messages=\(messageCount) total=\(totalMessageCount)",
                category: .ui
            )
            return
        }

        performInitialScroll(messageCount: anchorMessageCount, reason: reason, scrollAction: scrollAction)
    }

    private func performInitialScroll(
        messageCount: Int,
        reason: String,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard !hasStartedInitialAnchor else {
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial anchor already scheduled reason=\(reason) messages=\(messageCount)",
                category: .ui
            )
            return
        }

        hasStartedInitialAnchor = true
        initialAnchorWasForEmptyConversation = false
        // Single-message threads stay top-pinned at initial presentation.
        guard messageCount > 1 else {
            isReadyToShow = true
            Log.diagnostic(
                .chatView,
                level: .info,
                "ChatView initial anchor skipped for short conversation reason=\(reason) messages=\(messageCount)",
                category: .ui
            )
            return
        }

        Log.diagnostic(
            .chatView,
            level: .info,
            "ChatView initial anchor scheduled reason=\(reason) messages=\(messageCount)",
            category: .ui
        )
        scheduleBottomAnchor(
            taskKey: TaskKey.initialBottomAnchor,
            steps: [
                BottomAnchorStep(
                    delay: UIConfig.contentChangeScrollDelay,
                    animated: false,
                    logMessage: "ChatView initial scroll -> bottom anchor",
                    marksReady: true
                ),
                BottomAnchorStep(
                    delay: UIConfig.initialScrollDelay,
                    animated: false,
                    logMessage: "ChatView follow-up scroll -> bottom anchor"
                ),
                BottomAnchorStep(
                    delay: 0.25,
                    animated: false,
                    logMessage: "ChatView stabilization scroll (0.25s) -> bottom anchor"
                ),
                BottomAnchorStep(
                    delay: 0.75,
                    animated: false,
                    logMessage: "ChatView stabilization scroll (0.75s) -> bottom anchor"
                ),
                BottomAnchorStep(
                    delay: 1.5,
                    animated: false,
                    logMessage: "ChatView stabilization scroll (1.5s) -> bottom anchor"
                )
            ],
            scrollAction: scrollAction
        )
    }

    private func requestLatestWindowIfNeeded(knownTotalCount: Int?) {
        taskManager.run(TaskKey.latestWindow) { [loadLatestWindowIfNeeded] in
            await loadLatestWindowIfNeeded(knownTotalCount)
        }
    }

    private func scrollToBottom(
        messageCount: Int,
        delay: TimeInterval,
        includeStabilizationStep: Bool = false,
        knownTotalCount: Int? = nil,
        scrollAction: @escaping BottomAnchorAction
    ) {
        // Unlike performInitialScroll, single-message threads are not exempt here:
        // keyboard/focus changes still need to reveal an occluded bubble bottom.
        // ScrollView clamping keeps short content top-aligned either way.
        guard messageCount > 0 else { return }

        var steps = [
            BottomAnchorStep(
                delay: delay,
                animated: true,
                logMessage: "ChatView animated scroll -> bottom anchor"
            )
        ]

        if includeStabilizationStep {
            steps.append(
                BottomAnchorStep(
                    delay: max(UIConfig.initialScrollDelay, UIConfig.scrollAnimationDuration),
                    animated: false,
                    logMessage: "ChatView stabilization scroll after content change -> bottom anchor"
                )
            )
        }

        scheduleBottomAnchor(
            taskKey: TaskKey.bottomAnchor,
            knownTotalCount: knownTotalCount,
            steps: steps,
            scrollAction: scrollAction
        )
    }

    private func scheduleBottomAnchor(
        taskKey: String,
        knownTotalCount: Int? = nil,
        steps: [BottomAnchorStep],
        scrollAction: @escaping BottomAnchorAction
    ) {
        taskManager.run(taskKey) { [loadLatestWindowIfNeeded, sleep] in
            await loadLatestWindowIfNeeded(knownTotalCount)

            for step in steps {
                if step.delay > 0 {
                    await sleep(UInt64(step.delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }

                scrollAction(step)

                if step.marksReady {
                    self.isReadyToShow = true
                    if taskKey == TaskKey.initialBottomAnchor {
                        Log.diagnostic(
                            .chatView,
                            level: .info,
                            "ChatView initial anchor completed",
                            category: .ui
                        )
                    }
                }
            }
        }
    }
}
