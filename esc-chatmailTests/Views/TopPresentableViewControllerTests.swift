import XCTest
import UIKit
@testable import esc_chatmail

/// Moved from `ContactPresenterTests` with `TopPresentableViewController`'s
/// extraction from `ContactPresenter`; the assertions are unchanged.
@MainActor
final class TopPresentableViewControllerTests: XCTestCase {
    func testCanPresent_viewControllerOutsideWindow_returnsFalseUntilInstalled() {
        let viewController = UIViewController()
        viewController.loadViewIfNeeded()

        XCTAssertFalse(TopPresentableViewController.canPresent(from: viewController))

        let window = UIWindow()
        window.rootViewController = viewController
        window.makeKeyAndVisible()

        XCTAssertTrue(TopPresentableViewController.canPresent(from: viewController))
    }

    func testResolve_navigationController_returnsVisibleChild() {
        let rootViewController = UIViewController()
        let detailViewController = UIViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        navigationController.setViewControllers([rootViewController, detailViewController], animated: false)

        let window = UIWindow()
        window.rootViewController = navigationController
        window.makeKeyAndVisible()

        let resolved = TopPresentableViewController.resolve(startingFrom: navigationController)

        XCTAssertTrue(resolved === detailViewController)
    }

    func testResolve_presentedControllerOutsideWindow_isSkipped() {
        let rootViewController = TestViewController()
        let dismissedSheetHost = TestViewController()
        rootViewController.stubPresentedViewController = dismissedSheetHost

        let window = UIWindow()
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()

        rootViewController.loadViewIfNeeded()
        dismissedSheetHost.loadViewIfNeeded()

        let resolved = TopPresentableViewController.resolve(startingFrom: rootViewController)

        XCTAssertTrue(resolved === rootViewController)
    }

    /// A cancelled wait for a presenter must report `.cancelled`, not a missing
    /// presenter: `AttachmentGridView` and `EditContactView` log a failure only for
    /// `.noPresenter`, so a run replaced by a newer tap used to log a bogus error.
    ///
    /// Revert-check: returning `.noPresenter` from the `Task.sleepUnlessCancelled`
    /// guard in `TopPresentableViewController.present(_:resolvePresenter:)` makes
    /// this fail.
    func testPresent_cancelledWhileNoPresenter_reportsCancelled() async {
        let task = Task { @MainActor in
            await TopPresentableViewController.present(UIViewController()) { nil }
        }
        task.cancel()

        let outcome = await task.value

        XCTAssertEqual(outcome, .cancelled)
    }

    func testPresent_presenterAvailable_presentsAndReportsPresented() async {
        let presenter = TestViewController()
        let viewController = UIViewController()

        let outcome = await TopPresentableViewController.present(viewController) { presenter }

        XCTAssertEqual(outcome, .presented)
        XCTAssertTrue(presenter.lastPresented === viewController)
    }
}

private final class TestViewController: UIViewController {
    var stubPresentedViewController: UIViewController?
    private(set) var lastPresented: UIViewController?

    override var presentedViewController: UIViewController? {
        stubPresentedViewController
    }

    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        lastPresented = viewControllerToPresent
    }
}
