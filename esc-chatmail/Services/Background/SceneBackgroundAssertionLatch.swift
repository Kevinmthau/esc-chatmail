import Foundation
import UIKit

/// Ends a scene-background execution assertion exactly once, whether the arm
/// completes normally or UIKit's expiration handler fires first — whichever
/// runs first wins; later calls are ignored. The expiration handler must end
/// the assertion itself: a background task left unended past its grant is a
/// watchdog kill, not a suspension.
///
/// MainActor-isolated: the scene-background arm begins and ends the assertion
/// on the main actor, and UIKit delivers expiration on the main thread — the
/// handler adopts that isolation synchronously (`MainActor.assumeIsolated`)
/// because UIKit expects the assertion ended before the handler returns; a
/// hop through a later main-queue turn leaves it alive past the grant.
@MainActor
final class SceneBackgroundAssertionLatch {
    private var taskId = UIBackgroundTaskIdentifier.invalid

    func begin(name: String) {
        // Exactly-once discipline both ways: a second begin() would overwrite
        // taskId and leak the first assertion.
        guard taskId == .invalid else { return }
        taskId = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                self?.end()
            }
        }
    }

    func end() {
        guard taskId != .invalid else { return }
        let id = taskId
        taskId = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }
}
