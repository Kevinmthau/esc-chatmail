#if os(macOS)
import AppKit

/// Forwards the Mac events the foreground sync session follows
/// (`AppLifecyclePolicy.SystemEvent`): the app becoming active, and the system
/// going to sleep and waking.
///
/// It observes for the life of the process rather than from a view, so the
/// events still arrive while every window is closed.
@MainActor
final class MacSystemLifecycleObserver {
    static let shared = MacSystemLifecycleObserver()

    private var handler: (@MainActor (AppLifecyclePolicy.SystemEvent) -> Void)?
    private var observations: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    /// Delivers each event to `handler` on the main actor. A later call
    /// replaces the handler and keeps the one set of observations.
    func start(handler: @escaping @MainActor (AppLifecyclePolicy.SystemEvent) -> Void) {
        self.handler = handler
        guard observations.isEmpty else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, in: workspaceCenter, as: .systemWillSleep)
        observe(NSWorkspace.didWakeNotification, in: workspaceCenter, as: .systemDidWake)
        observe(NSApplication.didBecomeActiveNotification, in: .default, as: .applicationDidBecomeActive)
    }

    private func observe(
        _ name: Notification.Name,
        in center: NotificationCenter,
        as event: AppLifecyclePolicy.SystemEvent
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handler?(event)
            }
        }
        observations.append((center: center, token: token))
    }
}
#endif
