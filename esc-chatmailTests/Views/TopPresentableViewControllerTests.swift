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
}

private final class TestViewController: UIViewController {
    var stubPresentedViewController: UIViewController?

    override var presentedViewController: UIViewController? {
        stubPresentedViewController
    }
}
