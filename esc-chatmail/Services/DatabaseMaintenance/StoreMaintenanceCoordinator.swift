import Foundation

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
        operation: () async -> Bool
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

    func runExclusivelyWhenStoreIsIdle(
        operationName: String,
        operation: () async -> Bool
    ) async -> Bool {
        guard !isRunning else {
            Log.info("Skipping \(operationName); database maintenance already running", category: .coreData)
            return false
        }

        isRunning = true
        defer { isRunning = false }

        guard let request = await syncRunCoordinator.makeAccountWorkRequest(),
              let maintenanceRun = await syncRunCoordinator.acquireRun(
                  kind: .maintenance,
                  for: request
              ) else {
            Log.info("Skipping \(operationName); account transition invalidated maintenance", category: .coreData)
            return false
        }

        let result = await operation()
        await syncRunCoordinator.endRun(maintenanceRun)
        return result
    }
}
