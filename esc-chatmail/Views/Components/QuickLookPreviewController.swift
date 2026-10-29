import SwiftUI
import QuickLook
import CoreData

struct QuickLookPresentation: Identifiable {
    let id = UUID()
    let previewItems: [AttachmentPreviewItem]
    let selectedIndex: Int

    init?(attachments: [Attachment], selectedAttachment: Attachment) {
        let previewItems = attachments.compactMap { attachment in
            AttachmentPreviewItem(attachment: attachment)
        }
        guard let selectedIndex = previewItems.firstIndex(where: {
            $0.attachment == selectedAttachment
        }) else {
            return nil
        }

        self.previewItems = previewItems
        self.selectedIndex = selectedIndex
    }
}

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
    /// briefly through a transition). Returns `false` when nothing could present,
    /// so the caller can clear its state and let the next tap try again.
    ///
    /// - Parameter present: Presents the controller and reports whether it did;
    ///   tests inject one that presents from a test window.
    @MainActor
    @discardableResult
    static func present(
        _ presentation: QuickLookPresentation,
        onDismiss: @escaping () -> Void,
        present: @MainActor (UIViewController) async -> Bool = { await TopPresentableViewController.present($0) }
    ) async -> Bool {
        let controller = QuickLookPreviewController(presentation: presentation)
        controller.onDismiss = onDismiss
        guard await present(controller) else { return false }
        presentedControllers.add(controller)
        return true
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
    @MainActor
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

class AttachmentPreviewItem: NSObject, QLPreviewItem {
    let attachment: Attachment
    private var _fileURL: URL?
    
    init?(attachment: Attachment) {
        self.attachment = attachment
        super.init()

        guard let url = Self.fileURL(for: attachment) else {
            return nil
        }
        self._fileURL = url
    }

    static func fileURL(for attachment: Attachment) -> URL? {
        // Remote paths must prove the composite message/attachment identity;
        // an ID-only legacy path may point at a sibling message's bytes.
        let readablePaths = [
            attachment.readableLocalURLValue,
            attachment.readablePreviewURLValue
        ].compactMap { $0 }
        return readablePaths.lazy
            .compactMap({ AttachmentPaths.fullURL(for: $0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }
    
    var previewItemURL: URL? {
        return _fileURL
    }
    
    var previewItemTitle: String? {
        return attachment.filename
    }
}
