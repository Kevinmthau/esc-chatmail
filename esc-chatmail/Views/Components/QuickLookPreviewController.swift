import UIKit
import QuickLook

/// Quick Look presented as its own UIKit modal, the way Mail and Files show it.
///
/// It used to be a `QLPreviewController` wrapped in a navigation controller inside
/// a SwiftUI `.sheet`, which made a preview nearly impossible to put away: Quick
/// Look draws the document in a remote view the sheet cannot track, so a downward
/// drag on the content only scrolled the document, and because Quick Look was not
/// the presented controller it showed no Done button. The only way out was a
/// precise drag on the thin title bar. Presented directly, Quick Look owns its
/// dismissal: a Done button plus its own pull-down on the content, and the
/// transition does not fight the document's scrolling.
final class QuickLookPreviewController: QLPreviewController, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    /// The presentation is an immutable snapshot; QLPreviewController owns
    /// subsequent paging without SwiftUI resetting it.
    private let previewItems: [AttachmentPreviewItem]
    /// Called once Quick Look has finished dismissing itself (Done or pull-down),
    /// so the SwiftUI owner can clear the state that opened it.
    var onDismiss: (() -> Void)?

    init(presentation: QuickLookPresentation) {
        previewItems = presentation.previewItems
        super.init(nibName: nil, bundle: nil)
        dataSource = self
        delegate = self
        currentPreviewItemIndex = Self.clampedPreviewIndex(
            presentation.selectedIndex,
            itemCount: previewItems.count
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    static func clampedPreviewIndex(_ index: Int, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return min(max(index, 0), itemCount - 1)
    }

    /// Every controller `present` showed, held weakly so a dismissed one is not
    /// kept alive. `dismissAll()` walks it at the account boundary.
    private static let presentedControllers = NSHashTable<QuickLookPreviewController>.weakObjects()

    /// Presents `presentation` over whatever is on screen, from the topmost
    /// presentable controller (`TopPresentableViewController`, which retries
    /// briefly through a transition). Reports whether it presented, or why not,
    /// so the caller can clear the state of a presentation that never appeared.
    ///
    /// - Parameter present: Presents the controller and reports what it did;
    ///   tests inject one that presents from a test window.
    @discardableResult
    static func present(
        _ presentation: QuickLookPresentation,
        onDismiss: @escaping () -> Void,
        present: @MainActor (UIViewController) async -> TopPresentableViewController.Outcome = {
            await TopPresentableViewController.present($0)
        }
    ) async -> TopPresentableViewController.Outcome {
        let controller = QuickLookPreviewController(presentation: presentation)
        controller.onDismiss = onDismiss
        let outcome = await present(controller)
        guard outcome == .presented else { return outcome }
        presentedControllers.add(controller)
        return outcome
    }

    /// Dismisses every Quick Look `present` showed that is still on screen, along
    /// with anything presented over it.
    ///
    /// The `.sheet` this replaced went away with the mailbox it hung from. This
    /// modal hangs from the topmost controller, usually the root hosting
    /// controller, which outlives the mailbox, so without this a sign-out or a
    /// revoked credential left the previous account's document on screen over
    /// the sign-in view, its preview items still holding that account's
    /// `Attachment` objects. `ContentView` calls it when the mailbox closes.
    static func dismissAll() {
        for controller in presentedControllers.allObjects {
            controller.presentingViewController?.dismiss(animated: false)
        }
        presentedControllers.removeAllObjects()
    }

    // MARK: - QLPreviewControllerDataSource

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return previewItems.count
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return previewItems[index]
    }

    // MARK: - QLPreviewControllerDelegate

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        onDismiss?()
    }
}
