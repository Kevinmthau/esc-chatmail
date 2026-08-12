import Foundation
import UIKit

/// Ends a scene-background execution assertion exactly once, whether the arm
/// completes normally or UIKit's expiration handler fires first — whichever
/// runs first wins; later calls are ignored. The expiration handler must end
/// the assertion itself: a background task left unended past its grant is a
/// watchdog kill, not a suspension.
///
/// MainActor-isolated: the scene-background arm begins and ends the assertion
/// on the main actor, and UIKit delivers expiration on the main thread (the
/// handler hops through a MainActor task because UIKit types it nonisolated).
@MainActor
final class SceneBackgroundAssertionLatch {
    private var taskId = UIBackgroundTaskIdentifier.invalid

    func begin(name: String) {
        taskId = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
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
