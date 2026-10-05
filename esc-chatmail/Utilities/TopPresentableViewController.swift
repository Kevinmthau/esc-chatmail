import UIKit

/// Finds the view controller that can present UIKit content right now — the
/// visible content of the foreground key window, walked up through every
/// presented controller still in a window — and presents from it.
///
/// SwiftUI presentation modifiers present from the hosting controller they are
/// attached to, so a prompt raised from the app root silently never appears
/// while a sheet covers it; presenting from here shows it over whatever is on
/// screen. Extracted from `ContactPresenter` so the Settings-app sign-out
/// prompt (`SettingsAppSignOutPrompter`) shares the same resolution and retry.
enum TopPresentableViewController {
    @MainActor
    static func resolve(startingFrom rootViewController: UIViewController) -> UIViewController {
        var topViewController = visibleContentViewController(from: rootViewController)

        while let presented = topViewController.presentedViewController {
            guard presented.viewIfLoaded?.window != nil, !presented.isBeingDismissed else { break }
            topViewController = visibleContentViewController(from: presented)
        }

        return topViewController
    }

    @MainActor
    static func canPresent(from viewController: UIViewController) -> Bool {
        guard viewController.viewIfLoaded?.window != nil, !viewController.isBeingDismissed else {
            return false
        }

        guard let presented = viewController.presentedViewController else {
            return true
        }

        return presented.isBeingDismissed
    }

    /// Presents `viewController` from `preferredPresenter` while it can still
    /// present, otherwise from the topmost presentable controller, retrying for
    /// up to a second (20 × 50ms) while a transition leaves no presenter.
    /// Returns `false` when no presenter appeared or the task was cancelled.
    @MainActor
    @discardableResult
    static func present(_ viewController: UIViewController, preferredPresenter: UIViewController? = nil) async -> Bool {
        for _ in 0..<20 {
            if let presenter = resolvePresenter(preferredPresenter: preferredPresenter) {
                presenter.present(viewController, animated: true)
                return true
            }

            guard await Task.sleepUnlessCancelled(nanoseconds: 50_000_000) else { return false }
        }

        return false
    }

    @MainActor
    private static func visibleContentViewController(from viewController: UIViewController) -> UIViewController {
        if let navigationController = viewController as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleContentViewController(from: visibleViewController)
        }

        if let tabBarController = viewController as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return visibleContentViewController(from: selectedViewController)
        }

        return viewController
    }

    @MainActor
    private static func foregroundTopViewController() -> UIViewController? {
        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }

        let windows = windowScenes.flatMap(\.windows)
        let window = windows.first(where: \.isKeyWindow)
            ?? windows.first(where: { !$0.isHidden && $0.windowLevel == .normal })

        guard let rootViewController = window?.rootViewController else { return nil }
        return resolve(startingFrom: rootViewController)
    }

    @MainActor
    private static func resolvePresenter(preferredPresenter: UIViewController?) -> UIViewController? {
        if let preferredPresenter, canPresent(from: preferredPresenter) {
            return preferredPresenter
        }

        guard let topViewController = foregroundTopViewController(), canPresent(from: topViewController) else {
            return nil
        }

        return topViewController
    }
}
