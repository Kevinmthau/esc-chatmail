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

        await syncRunCoordinator.waitUntilIdle()

        guard !isRunning else {
            Log.info("Skipping \(operationName); database maintenance already running", category: .coreData)
            return false
        }

        isRunning = true
        defer { isRunning = false }

        return await operation()
    }
}
