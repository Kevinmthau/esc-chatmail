import Foundation
import UIKit

/// Carries a store-load failure from the startup bootstrap to
/// `AppLoadingView`, and its Try Again and Reset Mailbox actions back. Before
/// this, a failed load left the launch spinner up forever with no message.
@MainActor
final class AppLoadingModel: ObservableObject {
    static let shared = AppLoadingModel()

    @Published private(set) var storeLoadFailure: AppLoadingPolicy.StoreLoadFailureNotice?

    private let requestRetry: @Sendable () async -> Void
    private let resetStore: @MainActor () -> CoreDataStack.StoreResetOutcome
    private let availableCapacityBytes: @Sendable () -> Int64?
    private let isProtectedDataAvailable: @MainActor () -> Bool
    /// Consecutive failures toward offering Reset Mailbox
    /// (`AppLoadingPolicy.resetEligibleFailureCount`).
    private var resetEligibleFailureCount = 0

    /// `requestRetry` defaults inside the body rather than as a default
    /// argument: a cross-actor call in a default-argument closure compiles
    /// without `await`, and the `await` it seems to need fails the build.
    init(
        requestRetry: (@Sendable () async -> Void)? = nil,
        resetStore: @escaping @MainActor () -> CoreDataStack.StoreResetOutcome = {
            CoreDataStack.shared.resetStoreAfterLoadFailure()
        },
        availableCapacityBytes: @escaping @Sendable () -> Int64? = {
            StoreVolumeFreeSpace.availableBytes()
        },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = {
            UIApplication.shared.isProtectedDataAvailable
        }
    ) {
        self.requestRetry = requestRetry ?? {
            await AppStartupBootstrap.shared.requestPersistenceRetry()
        }
        self.resetStore = resetStore
        self.availableCapacityBytes = availableCapacityBytes
        self.isProtectedDataAvailable = isProtectedDataAvailable
    }

    func showStoreLoadFailure(_ error: Error) {
        let availableBytes = availableCapacityBytes()
        let isFreeSpaceKnown = availableBytes != nil
        let kind = AppLoadingPolicy.storeLoadFailureKind(
            for: error,
            availableCapacityBytes: availableBytes
        )
        resetEligibleFailureCount = AppLoadingPolicy.resetEligibleFailureCount(
            afterFailureOf: kind,
            previousCount: resetEligibleFailureCount,
            isProtectedDataAvailable: isProtectedDataAvailable(),
            isFreeSpaceKnown: isFreeSpaceKnown
        )
        storeLoadFailure = AppLoadingPolicy.storeLoadFailureNotice(
            for: kind,
            resetEligibleFailureCount: resetEligibleFailureCount,
            isFreeSpaceKnown: isFreeSpaceKnown
        )
    }

    func clearStoreLoadFailure() {
        storeLoadFailure = nil
        resetEligibleFailureCount = 0
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

    /// Backs up and removes the store, then retries, which loads an empty
    /// store that sync refills. Reached from the confirmation behind Reset
    /// Mailbox, so it does nothing unless the notice on screen still offers
    /// the reset: a failure of another kind may have replaced it while the
    /// confirmation was up.
    ///
    /// Runs on the main actor, where every launch attempt loads the store, so
    /// no load can start between the stack's checks and the removal. The
    /// backup is a file copy, which APFS performs as a clone, so it does not
    /// stall the main thread on a large store.
    func resetMailbox() {
        guard storeLoadFailure?.offersMailboxReset == true else { return }
        switch resetStore() {
        case .removed:
            // The empty store has to earn the offer again: resetting it a
            // second time cannot help.
            resetEligibleFailureCount = 0
            retry()
        case .notResettable:
            // No resettable failure is latched any more (the store opened, or
            // a retry is under way), or the disk filled or could no longer be
            // measured since the offer; the next attempt reports what is true.
            retry()
        case .failed:
            storeLoadFailure = AppLoadingPolicy.mailboxResetFailedNotice
        }
    }
}
