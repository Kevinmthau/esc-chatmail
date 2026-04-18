import Foundation
import CoreData
import CoreGraphics
import Combine

@MainActor
final class ChatMessagesCoordinator: ObservableObject {
    private enum TaskKey {
        static let bottomAnchor = "bottomAnchor"
        static let initialBottomAnchor = "initialBottomAnchor"
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
    typealias Sleep = (UInt64) async -> Void

    @Published private(set) var isReadyToShow = false
    @Published private(set) var contactRefreshToken = 0
    @Published private(set) var senderGroupingKeysByEmail: [String: String] = [:]

    private let loadLatestWindowIfNeeded: AsyncAction
    private let markConversationAsReadIfNeeded: () -> Void
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

    init(
        scrollState: VirtualScrollState,
        viewModel: ChatViewModel,
        chatDependencies: ChatDependencies,
        sleep: @escaping Sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.loadLatestWindowIfNeeded = {
            await scrollState.loadLatestWindowIfNeeded()
        }
        self.markConversationAsReadIfNeeded = {
            viewModel.markConversationAsReadIfNeeded()
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
            await chatDependencies.participantLoader.senderGroupingKeys(for: senderEmails)
        }
        self.invalidateContactsCache = chatDependencies.invalidateContactsCache
        self.clearPersonCache = chatDependencies.clearPersonCache
        self.sleep = sleep
    }

    init(
        loadLatestWindowIfNeeded: @escaping AsyncAction,
        markConversationAsReadIfNeeded: @escaping () -> Void,
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
        visibleMessages: [Message],
        totalMessageCount: Int,
        scrollAction: @escaping BottomAnchorAction
    ) {
        markConversationAsReadIfNeeded()
        initializeReplyingTo(lastMessage)

        if !isReadyToShow && !visibleMessages.isEmpty {
            performInitialScroll(messageCount: messageCount, scrollAction: scrollAction)
        } else if messageCount == 0 && totalMessageCount == 0 {
            isReadyToShow = true
        }

        loadResolvedDisplayName()
        prefetchVisibleContent(from: visibleMessages)
        refreshSenderGroupingKeys(using: visibleMessages)
    }

    func handleDisappear() {
        taskManager.cancelAll()
        cancelPrefetch()
    }

    func handleDisplayedMessagesChange(
        oldIDs: [NSManagedObjectID],
        newIDs: [NSManagedObjectID],
        visibleMessages: [Message],
        messageCount: Int,
        scrollAction: @escaping BottomAnchorAction
    ) {
        if !isReadyToShow && !newIDs.isEmpty {
            performInitialScroll(messageCount: messageCount, scrollAction: scrollAction)
        }

        if oldIDs != newIDs {
            prefetchVisibleContent(from: visibleMessages)
            refreshSenderGroupingKeys(using: visibleMessages)
        }
    }

    func handleMessageCountChange(
        oldCount: Int,
        newCount: Int,
        lastMessage: Message?,
        scrollAction: @escaping BottomAnchorAction
    ) {
        if !isReadyToShow && newCount > 0 {
            performInitialScroll(messageCount: newCount, scrollAction: scrollAction)
        } else if isReadyToShow && newCount > oldCount {
            updateReplyingToIfNewSubject(lastMessage)
            scrollToBottom(
                messageCount: newCount,
                delay: UIConfig.contentChangeScrollDelay,
                scrollAction: scrollAction
            )
        }

        loadResolvedDisplayName()
    }

    func handleKeyboardHeightChange(
        oldHeight: CGFloat,
        newHeight: CGFloat,
        messageCount: Int,
        scrollAction: @escaping BottomAnchorAction
    ) {
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
        scrollAction: @escaping BottomAnchorAction
    ) {
        if !isFocused {
            scrollToBottom(
                messageCount: messageCount,
                delay: UIConfig.initialScrollDelay,
                scrollAction: scrollAction
            )
        }
    }

    func handleContactStoreDidChange(visibleMessages: [Message]) {
        taskManager.run("contactRefresh") { [invalidateContactsCache, clearPersonCache] in
            await invalidateContactsCache()
            await clearPersonCache()

            guard !Task.isCancelled else { return }

            self.contactRefreshToken &+= 1
            self.loadResolvedDisplayName()
            self.refreshSenderGroupingKeys(using: visibleMessages)
        }
    }

    func senderRunKey(
        for message: Message?,
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

    private func prefetchVisibleContent(from visibleMessages: [Message]) {
        let config = VirtualScrollConfiguration.default
        let prefetchLimit = config.visibleItemCount + config.bufferSize
        let recentMessages = visibleMessages.suffix(prefetchLimit)
        let messageIds = recentMessages.map(\.id)
        let senderEmails = recentMessages.compactMap(\.senderEmail)

        prefetchRecentContent(messageIds, senderEmails)
    }

    private func refreshSenderGroupingKeys(using visibleMessages: [Message]) {
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

    private func senderEmail(for message: Message) -> String? {
        if let senderEmail = message.senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !senderEmail.isEmpty {
            return senderEmail
        }

        return message.participants?
            .first(where: { $0.participantKind == .from })?
            .person?
            .email
    }

    private func performInitialScroll(
        messageCount: Int,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard shouldUseBottomAnchoring(for: messageCount) else {
            isReadyToShow = true
            return
        }

        scheduleBottomAnchor(
            taskKey: TaskKey.initialBottomAnchor,
            steps: [
                BottomAnchorStep(
                    delay: UIConfig.contentChangeScrollDelay,
                    animated: false,
                    logMessage: "ChatView initial scroll -> bottom anchor"
                ),
                BottomAnchorStep(
                    delay: UIConfig.initialScrollDelay,
                    animated: false,
                    logMessage: "ChatView follow-up scroll -> bottom anchor",
                    marksReady: true
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

    private func scrollToBottom(
        messageCount: Int,
        delay: TimeInterval,
        scrollAction: @escaping BottomAnchorAction
    ) {
        guard shouldUseBottomAnchoring(for: messageCount) else { return }

        scheduleBottomAnchor(
            taskKey: TaskKey.bottomAnchor,
            steps: [
                BottomAnchorStep(
                    delay: delay,
                    animated: true,
                    logMessage: "ChatView animated scroll -> bottom anchor"
                )
            ],
            scrollAction: scrollAction
        )
    }

    private func scheduleBottomAnchor(
        taskKey: String,
        steps: [BottomAnchorStep],
        scrollAction: @escaping BottomAnchorAction
    ) {
        taskManager.run(taskKey) { [loadLatestWindowIfNeeded, sleep] in
            await loadLatestWindowIfNeeded()

            for step in steps {
                if step.delay > 0 {
                    await sleep(UInt64(step.delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }

                scrollAction(step)

                if step.marksReady {
                    self.isReadyToShow = true
                }
            }
        }
    }

    private func shouldUseBottomAnchoring(for messageCount: Int) -> Bool {
        messageCount > 1
    }
}
