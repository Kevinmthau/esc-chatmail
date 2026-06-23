import Foundation

enum RemoteConfigFlag: String, Sendable {
    case syncRecoveryEnabled
    case previewRenderingExperimentsEnabled
    case backgroundRefreshEnabled
    case remoteImageLoadingEnabled
    case databaseMaintenanceEnabled
}

protocol RemoteConfigProvider: Sendable {
    func isEnabled(_ flag: RemoteConfigFlag) async -> Bool
}

actor StaticRemoteConfigProvider: RemoteConfigProvider {
    static let shared = StaticRemoteConfigProvider()

    private var flags: [RemoteConfigFlag: Bool]

    init(flags: [RemoteConfigFlag: Bool] = [:]) {
        self.flags = flags
    }

    func isEnabled(_ flag: RemoteConfigFlag) async -> Bool {
        flags[flag] ?? true
    }

    func setEnabled(_ flag: RemoteConfigFlag, _ isEnabled: Bool) {
        flags[flag] = isEnabled
    }
}
