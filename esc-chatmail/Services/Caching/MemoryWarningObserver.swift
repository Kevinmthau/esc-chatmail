import Foundation

/// Protocol for types that respond to memory warnings
protocol MemoryWarningHandler: AnyObject, Sendable {
    /// Called when the system issues a memory warning
    func handleMemoryWarning() async
}

/// Helper class that observes memory warnings and forwards them to a handler.
/// Encapsulates the observation boilerplate for actor-based caches. The signal
/// comes from `MemoryPressureEventSource`: UIKit's memory-warning notification
/// on iOS, a dispatch memory-pressure source on the Mac.
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
///
/// `@unchecked Sendable`: `start` runs on the main actor, and `stop` from the
/// owner's teardown or `deinit`, after which nothing else touches it.
final class MemoryWarningObserver: @unchecked Sendable {
    private let eventSource: MemoryPressureEventSource
    private weak var handler: (any MemoryWarningHandler)?

    init(eventSource: MemoryPressureEventSource = MemoryPressureEventSource()) {
        self.eventSource = eventSource
    }

    /// Starts observing memory warnings. Must be called from an async context after init.
    /// - Parameter handler: The handler to notify when memory warnings occur
    @MainActor
    func start(handler: any MemoryWarningHandler) {
        self.handler = handler

        eventSource.start { [weak self] in
            guard let self = self else { return }
            Task {
                await self.handler?.handleMemoryWarning()
            }
        }
    }

    /// Stops observing memory warnings
    func stop() {
        eventSource.stop()
        handler = nil
    }

    deinit {
        stop()
    }
}
