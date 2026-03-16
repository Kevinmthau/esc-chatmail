import XCTest
import UIKit
@testable import esc_chatmail

@MainActor
final class ContactPresenterTests: XCTestCase {
    func testCanPresentRequiresWindowHierarchy() {
        let viewController = UIViewController()
        viewController.loadViewIfNeeded()

        XCTAssertFalse(ContactPresenter.canPresent(from: viewController))

        let window = UIWindow()
        window.rootViewController = viewController
        window.makeKeyAndVisible()

        XCTAssertTrue(ContactPresenter.canPresent(from: viewController))
    }

    func testTopPresentableViewControllerUsesVisibleNavigationControllerChild() {
        let rootViewController = UIViewController()
        let detailViewController = UIViewController()
        let navigationController = UINavigationController(rootViewController: rootViewController)
        navigationController.setViewControllers([rootViewController, detailViewController], animated: false)

        let window = UIWindow()
        window.rootViewController = navigationController
        window.makeKeyAndVisible()

        let resolved = ContactPresenter.topPresentableViewController(startingFrom: navigationController)

        XCTAssertTrue(resolved === detailViewController)
    }

    func testTopPresentableViewControllerSkipsPresentedControllerOutsideWindowHierarchy() {
        let rootViewController = TestViewController()
        let dismissedSheetHost = TestViewController()
        rootViewController.stubPresentedViewController = dismissedSheetHost

        let window = UIWindow()
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()

        rootViewController.loadViewIfNeeded()
        dismissedSheetHost.loadViewIfNeeded()

        let resolved = ContactPresenter.topPresentableViewController(startingFrom: rootViewController)

        XCTAssertTrue(resolved === rootViewController)
    }
}

private final class TestViewController: UIViewController {
    var stubPresentedViewController: UIViewController?

    override var presentedViewController: UIViewController? {
        stubPresentedViewController
    }
}
