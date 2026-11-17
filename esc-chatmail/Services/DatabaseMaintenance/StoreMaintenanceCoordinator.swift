import Foundation
import os

/// Runs one store-wide maintenance operation at a time, as the exclusive
/// `.maintenance` run of the sync boundary, so no sync, pending-action flush
/// or second maintenance operation writes the store beside it.
///
/// The operation runs in a task registered with its run
/// (`SyncRunCoordinator.acquireRunWithTask`). Two things cancel that task:
/// an account transition's `beginQuiescence()`, and the cancellation of the
/// caller's own task, which is how a background task's expiration reaches
/// it. Either way the operation is still awaited to its end and the run is
/// ended after it: cancelling shortens the wait, it does not skip it.
actor StoreMaintenanceCoordinator {
    static let shared = StoreMaintenanceCoordinator()

    private var isRunning = false
    private let syncRunCoordinator: SyncRunCoordinator
    private let remoteConfig: any RemoteConfigProvider

    init(
        syncRunCoordinator: SyncRunCoordinator = .shared,
        remoteConfig: any RemoteConfigProvider = StaticRemoteConfigProvider.shared
    ) {
        self.syncRunCoordinator = syncRunCoordinator
        self.remoteConfig = remoteConfig
    }

    func runWhenStoreIsIdle(
        operationName: String,
        operation: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        guard await remoteConfig.isEnabled(.databaseMaintenanceEnabled) else {
            Log.info("Skipping \(operationName); database maintenance is disabled by remote config", category: .coreData)
            return false
        }

        return await runExclusivelyWhenStoreIsIdle(
            operationName: operationName,
            operation: operation
        )
    }

    /// `resultOfExclusiveRun` for an operation that answers whether it
    /// succeeded. An operation that was not admitted did not succeed.
    func runExclusivelyWhenStoreIsIdle(
        operationName: String,
        operation: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        await resultOfExclusiveRun(operationName: operationName, operation: operation) ?? false
    }

    /// Runs `operation` as the exclusive maintenance run and returns what it
    /// returned, or nil if it was not admitted and never ran: another
    /// maintenance operation was running, the caller was cancelled while it
    /// waited for the boundary, or an account transition began.
    func resultOfExclusiveRun<Value: Sendable>(
        operationName: String,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        guard !isRunning else {
            Log.info("Skipping \(operationName); database maintenance already running", category: .coreData)
            return nil
        }

        isRunning = true
        defer { isRunning = false }

        // The run's task is `Task<Void, Error>` for every kind of run, so
        // the operation's value leaves it here.
        let result = OSAllocatedUnfairLock<Value?>(initialState: nil)
        guard let request = await syncRunCoordinator.makeAccountWorkRequest(),
              let maintenanceRun = await syncRunCoordinator.acquireRunWithTask(
                  kind: .maintenance,
                  for: request,
                  taskBuilder: { _ in
                      Task {
                          let value = await operation()
                          result.withLock { $0 = value }
                      }
                  }
              ) else {
            Log.info("Skipping \(operationName); account transition or cancellation invalidated maintenance", category: .coreData)
            return nil
        }

        // The operation is not a child of this task, so the caller's
        // cancellation is handed to it here.
        await withTaskCancellationHandler {
            _ = try? await maintenanceRun.task.value
        } onCancel: {
            maintenanceRun.task.cancel()
        }
        await syncRunCoordinator.endRun(maintenanceRun.run)
        return result.withLock { $0 }
    }
}
