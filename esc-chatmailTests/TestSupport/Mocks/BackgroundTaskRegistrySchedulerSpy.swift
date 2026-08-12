import Foundation
import BackgroundTasks
@testable import esc_chatmail

/// Records what a `BackgroundTaskRegistry` hands to its `BGTaskScheduler`
/// seams, and builds registries wired to itself. The real scheduler cannot
/// back hosted unit tests: launch handlers may only be registered during app
/// launch (re-registration is an Apple assertion failure that aborts the
/// process) and the simulator rejects submits outright.
final class BackgroundTaskRegistrySchedulerSpy {
    var registeredIdentifiers: [String] = []
    var submittedRequests: [BGTaskRequest] = []
    var pendingIdentifiers: Set<String> = []
    var pendingFetchCount = 0

    /// A registry whose three scheduler seams record into this spy.
    func makeRegistry() -> BackgroundTaskRegistry {
        BackgroundTaskRegistry(
            registerLaunchHandler: { [self] identifier, _ in
                registeredIdentifiers.append(identifier)
            },
            submitTaskRequest: { [self] request in
                submittedRequests.append(request)
            },
            pendingTaskIdentifiers: { [self] in
                pendingFetchCount += 1
                return pendingIdentifiers
            }
        )
    }
}
