import Foundation
import UIKit

/// Protocol for types that respond to memory warnings
protocol MemoryWarningHandler: AnyObject, Sendable {
    /// Called when the system issues a memory warning
    func handleMemoryWarning() async
}

/// Helper class that observes memory warning notifications and forwards them to a handler.
/// Encapsulates the NotificationCenter boilerplate for actor-based caches.
///
/// Usage in an actor:
/// ```
/// actor MyCache: MemoryWarningHandler {
///     private let memoryObserver = MemoryWarningObserver()
///
///     private init() {
///         Task { await memoryObserver.start(handler: self) }
///     }
///
///     func handleMemoryWarning() async {
///         // Clear caches
///     }
/// }
/// ```
final class MemoryWarningObserver: @unchecked Sendable {
    private var observer: (any NSObjectProtocol)?
    private weak var handler: (any MemoryWarningHandler)?

    init() {}

    /// Starts observing memory warnings. Must be called from an async context after init.
    /// - Parameter handler: The handler to notify when memory warnings occur
    @MainActor
    func start(handler: any MemoryWarningHandler) {
        self.handler = handler

        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.handler?.handleMemoryWarning()
            }
        }
    }

    /// Stops observing memory warnings
    func stop() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        handler = nil
    }

    deinit {
        stop()
    }
}
