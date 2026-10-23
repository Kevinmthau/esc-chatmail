import Foundation

/// Carries a store-load failure from the startup bootstrap to
/// `AppLoadingView`, and its Try Again button back to the bootstrap. Before
/// this, a failed load left the launch spinner up forever with no message.
@MainActor
final class AppLoadingModel: ObservableObject {
    static let shared = AppLoadingModel()

    @Published private(set) var storeLoadFailure: AppLoadingPolicy.StoreLoadFailureNotice?

    private let requestRetry: @Sendable () async -> Void
    private let availableCapacityBytes: @Sendable () -> Int64?

    /// `requestRetry` defaults inside the body rather than as a default
    /// argument: a cross-actor call in a default-argument closure compiles
    /// without `await`, and the `await` it seems to need fails the build.
    init(
        requestRetry: (@Sendable () async -> Void)? = nil,
        availableCapacityBytes: @escaping @Sendable () -> Int64? = {
            try? URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
        }
    ) {
        self.requestRetry = requestRetry ?? {
            await AppStartupBootstrap.shared.requestPersistenceRetry()
        }
        self.availableCapacityBytes = availableCapacityBytes
    }

    func showStoreLoadFailure(_ error: Error) {
        storeLoadFailure = AppLoadingPolicy.storeLoadFailureNotice(
            for: error,
            availableCapacityBytes: availableCapacityBytes()
        )
    }

    func clearStoreLoadFailure() {
        storeLoadFailure = nil
    }

    /// Returns to the spinner while the bootstrap retries; a retry that fails
    /// again shows the notice again.
    func retry() {
        storeLoadFailure = nil
        let requestRetry = self.requestRetry
        Task {
            await requestRetry()
        }
    }
}
