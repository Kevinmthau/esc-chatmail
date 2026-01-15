import Foundation
import CoreData

// MARK: - Pending Actions Manager

/// Manages a persistent queue of pending actions that need to be synced to Gmail.
/// Actions are stored in CoreData and processed when network is available.
///
/// The implementation is split across multiple files:
/// - `PendingActionsManagerProtocol.swift`: Protocol definition
/// - `PendingActionProcessor.swift`: Action execution and retry logic
/// - `PendingActionQueries.swift`: Query methods (count, hasPending, cancel)
///
/// Dependencies:
/// - NetworkMonitor: Handles connectivity detection
/// - ActionExecutor: Handles action execution against Gmail API
/// - PendingActionsManager: Coordinates queuing and processing
actor PendingActionsManager: PendingActionsManagerProtocol {
    static let shared = PendingActionsManager()

    // MARK: - Dependencies (internal for extensions)

    let coreDataStack: CoreDataStack
    let actionExecutor: ActionExecutorProtocol
    let networkMonitor: NetworkMonitorProtocol

    // MARK: - Configuration (internal for extensions)

    let maxRetries = 5
    let baseRetryDelay: TimeInterval = 2.0

    // MARK: - State

    private var isProcessing = false
    private var isInitialized = false
    private var pendingProcessTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Production initializer
    private init() {
        self.coreDataStack = CoreDataStack.shared
        self.actionExecutor = GmailActionExecutor()
        self.networkMonitor = AppNetworkMonitor.shared
    }

    /// Testable initializer with dependency injection
    init(
        coreDataStack: CoreDataStack,
        actionExecutor: ActionExecutorProtocol = GmailActionExecutor(),
        networkMonitor: NetworkMonitorProtocol = AppNetworkMonitor.shared
    ) {
        self.coreDataStack = coreDataStack
        self.actionExecutor = actionExecutor
        self.networkMonitor = networkMonitor
    }

    /// Sets up network monitoring on first use
    private func ensureInitialized() {
        guard !isInitialized else { return }
        isInitialized = true

        networkMonitor.onConnectivityChange = { [weak self] isConnected in
            guard isConnected else { return }
            Task { [weak self] in
                await self?.scheduleProcessing()
            }
        }
        networkMonitor.start()
    }

    /// Schedules processing with deduplication to prevent multiple concurrent processing tasks
    /// during network flaps (rapid connect/disconnect cycles)
    private func scheduleProcessing() {
        // If already processing or a task is pending, skip
        guard pendingProcessTask == nil, !isProcessing else { return }

        pendingProcessTask = Task { [weak self] in
            await self?.processAllPendingActions()
            await self?.clearPendingTask()
        }
    }

    private func clearPendingTask() {
        pendingProcessTask = nil
    }

    public func stopMonitoring() {
        networkMonitor.stop()
        isInitialized = false
    }

    // MARK: - Queue Actions

    public func queueAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]? = nil
    ) async {
        ensureInitialized()

        let context = coreDataStack.viewContext
        await context.perform {
            self.createPendingAction(
                in: context,
                type: type,
                messageId: messageId,
                payload: payload
            )
            context.saveOrLog(operation: "queue pending action: \(type.rawValue)")
        }

        if networkMonitor.isConnected {
            await processAllPendingActions()
        }
    }

    public func queueConversationAction(
        type: PendingAction.ActionType,
        conversationId: UUID,
        messageIds: [String]
    ) async {
        ensureInitialized()

        Log.info("Queueing \(type.rawValue) for \(messageIds.count) messages", category: .sync)

        let context = coreDataStack.viewContext
        let payload: [String: Any] = ["messageIds": messageIds]
        await context.perform {
            self.createPendingAction(
                in: context,
                type: type,
                conversationId: conversationId,
                payload: payload
            )
            context.saveOrLog(operation: "queue conversation action: \(type.rawValue)")
        }

        if networkMonitor.isConnected {
            await processAllPendingActions()
        }
    }

    private nonisolated func createPendingAction(
        in context: NSManagedObjectContext,
        type: PendingAction.ActionType,
        messageId: String? = nil,
        conversationId: UUID? = nil,
        payload: [String: Any]? = nil
    ) {
        let action = PendingAction(context: context)
        action.setValue(UUID(), forKey: "id")
        action.setValue(type.rawValue, forKey: "actionType")
        action.setValue(messageId, forKey: "messageId")
        action.setValue(conversationId, forKey: "conversationId")
        action.setValue(Date(), forKey: "createdAt")
        action.setValue("pending", forKey: "status")
        action.setValue(Int16(0), forKey: "retryCount")

        if let payload = payload,
           let payloadData = try? JSONSerialization.data(withJSONObject: payload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            action.setValue(payloadString, forKey: "payload")
        }
    }

    // MARK: - Process Actions

    public func processAllPendingActions() async {
        ensureInitialized()

        guard !isProcessing else { return }
        guard networkMonitor.isConnected else { return }

        isProcessing = true
        defer { isProcessing = false }

        let context = coreDataStack.newBackgroundContext()

        // Process actions one by one (uses extension methods)
        while let action = await fetchNextPendingAction(context: context) {
            await processAction(action, context: context)
        }

        await cleanupCompletedActions(context: context)
    }
}
