#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import esc_chatmail

/// The drop view over a Mac sheet's content (`View.macDraftFileDropOverlay`), mounted over the
/// kinds of field the New Message and Forward sheet has, in a window that is never shown.
///
/// AppKit gives a drag to the frontmost view under the pointer that is registered for what is
/// dragged. These tests walk the mounted views front to back by that rule and ask which one
/// is first, with the drop view over the content and, for the reason it is there, behind it.
///
/// HONEST SCOPE: the walk is this file's reading of AppKit's rule, not AppKit's own choice.
/// AppKit's own was asked once, through its private drag hit test, and gave the same answers
/// (`docs/mac-app-plan.md`, "Files"); a test does not call a private method. The sheet here
/// is a stand-in with SwiftUI's own fields, not `ComposeView`, which asks for Contacts as it
/// appears. And nothing here can press a SwiftUI button, so that the sheet's buttons still
/// work under the drop view is not pinned: a window that is never shown presses none.
@MainActor
final class MacComposeFileDropOverlayTests: XCTestCase {
    private enum Placement {
        case overTheContent
        case behindTheContent
    }

    @MainActor
    private final class Recorder {
        var accepts = true
        var dropped: [[URL]] = []
    }

    private struct SheetStandIn: View {
        let placement: Placement
        let recorder: Recorder
        @State private var recipient = ""
        @State private var message = ""
        @State private var note = "A note"

        var body: some View {
            switch placement {
            case .overTheContent:
                content.macDraftFileDropOverlay(
                    acceptsFiles: { recorder.accepts },
                    onDropFiles: { urls in
                        recorder.dropped.append(urls)
                        return true
                    }
                )
            case .behindTheContent:
                content.macDraftFileDrop(
                    acceptsFiles: { recorder.accepts },
                    onDropFiles: { urls in
                        recorder.dropped.append(urls)
                        return true
                    }
                )
            }
        }

        private var content: some View {
            VStack(spacing: 0) {
                TextField("To", text: $recipient)
                    .textFieldStyle(.plain)
                    .frame(height: MacComposeFileDropOverlayTests.fieldHeight)
                TextField("Message", text: $message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .frame(height: MacComposeFileDropOverlayTests.fieldHeight)
                TextEditor(text: $note)
                    .frame(height: MacComposeFileDropOverlayTests.editorHeight)
                Color.blue
                    .frame(height: MacComposeFileDropOverlayTests.emptyHeight)
            }
            .frame(width: MacComposeFileDropOverlayTests.size.width, height: MacComposeFileDropOverlayTests.size.height)
        }
    }

    private static let fieldHeight: CGFloat = 40
    private static let editorHeight: CGFloat = 100
    private static let emptyHeight: CGFloat = 80
    private static let size = CGSize(width: 400, height: fieldHeight * 2 + editorHeight + emptyHeight)

    // Window coordinates, y up; the stack is laid out from the top.
    private static let pointOnRecipientField = NSPoint(x: 200, y: size.height - fieldHeight / 2)
    private static let pointOnTextEditor = NSPoint(x: 200, y: emptyHeight + editorHeight / 2)
    private static let pointOnEmptySpace = NSPoint(x: 200, y: emptyHeight / 2)

    private var hosts: [MacOffscreenHost] = []

    override func tearDown() async throws {
        hosts.forEach { $0.close() }
        hosts = []
        try await super.tearDown()
    }

    private func mount(_ placement: Placement, recorder: Recorder? = nil) throws -> MacOffscreenHost {
        let host = MacOffscreenHost(
            window: try makeTestHostWindow(),
            size: Self.size,
            rootView: SheetStandIn(placement: placement, recorder: recorder ?? Recorder())
        )
        hosts.append(host)
        host.settle(for: 0.3)
        return host
    }

    /// Puts the caret in the first editable text field, which gives it a field editor: the
    /// view that takes a drag for a field.
    private func focusFirstField(in host: MacOffscreenHost) throws {
        let field = try XCTUnwrap(
            Self.views(in: host.hostingView).compactMap { $0 as? NSTextField }.first(where: \.isEditable),
            "The stand-in has no text field"
        )
        XCTAssertTrue(host.window.makeFirstResponder(field))
        host.settle(for: 0.2)
        XCTAssertNotNil(field.currentEditor(), "The field has no field editor to take a drag")
    }

    // MARK: - AppKit's rule, read from the mounted views

    private static let fileDragTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        NSPasteboard.PasteboardType("NSFilenamesPboardType")
    ]

    private static func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views(in:))
    }

    /// The frontmost view under `point` that is registered for dragged files: a view's
    /// subviews are in front of it, and the last subview is in front of the others.
    private static func fileDragDestination(under view: NSView, at point: NSPoint) -> NSView? {
        guard !view.isHidden else { return nil }
        for subview in view.subviews.reversed() {
            if let found = fileDragDestination(under: subview, at: point) {
                return found
            }
        }
        let takesFiles = !fileDragTypes.isDisjoint(with: view.registeredDraggedTypes)
        return takesFiles && view.convert(view.bounds, to: nil).contains(point) ? view : nil
    }

    private func fileDragDestination(in host: MacOffscreenHost, at point: NSPoint) -> NSView? {
        Self.fileDragDestination(under: host.hostingView, at: point)
    }

    // MARK: - Why the drop view is over the content

    /// The reason for the overlay, pinned so it is not "simplified" into the chat's
    /// arrangement: behind the content, the fields are in front of the drop view, and both
    /// take a file drag themselves and type the file's path.
    func testBehindTheContent_aFieldWithTheCaret_andATextEditor_areInFrontOfTheDropView() throws {
        let host = try mount(.behindTheContent)
        try focusFirstField(in: host)

        let overField = try XCTUnwrap(fileDragDestination(in: host, at: Self.pointOnRecipientField))
        let overEditor = try XCTUnwrap(fileDragDestination(in: host, at: Self.pointOnTextEditor))

        XCTAssertTrue(overField is NSTextView, "\(type(of: overField))")
        XCTAssertTrue(overEditor is NSTextView, "\(type(of: overEditor))")
        XCTAssertTrue(fileDragDestination(in: host, at: Self.pointOnEmptySpace) is MacDraftFileDropView)
    }

    /// Revert-check: changing `overlay` to `background` in `View.macDraftFileDropOverlay`
    /// makes this fail: a file dropped on the field with the caret, or on the text editor, is
    /// typed into it as a path.
    func testOverTheContent_theDropViewIsInFrontEverywhere() throws {
        let host = try mount(.overTheContent)
        try focusFirstField(in: host)

        for point in [Self.pointOnRecipientField, Self.pointOnTextEditor, Self.pointOnEmptySpace] {
            let destination = try XCTUnwrap(fileDragDestination(in: host, at: point), "\(point)")
            XCTAssertTrue(destination is MacDraftFileDropView, "\(type(of: destination)) at \(point)")
        }
    }

    /// The drop view is registered for files and nothing else, so a drag of text is still
    /// the field's.
    ///
    /// Revert-check: registering `MacDraftFileDropView` for `.string` as well makes this fail.
    func testOverTheContent_theDropViewIsRegisteredForFilesOnly() throws {
        let host = try mount(.overTheContent)
        let dropView = try XCTUnwrap(host.first(MacDraftFileDropView.self))

        XCTAssertEqual(dropView.registeredDraggedTypes, [.fileURL])
    }

    /// Two things keep a click from being the drop view's, and either one alone is enough
    /// for AppKit's hit test: the view's own `hitTest` is nil, and the overlay is left out of
    /// SwiftUI's hit testing, which hides it from AppKit's as well.
    ///
    /// Revert-check: answering `super.hitTest(point)` from `MacDraftFileDropView.hitTest` and
    /// deleting `.allowsHitTesting(false)` from `View.macDraftFileDropOverlay`, both, make
    /// this fail: a click on a field is the drop view's. HONEST SCOPE: undoing either one
    /// alone leaves it passing (run both ways, 2026-11-13), so it does not pin each of them;
    /// `ComposeFileDropSourceTests` pins the modifier, and `MacDraftFileDropViewTests` the
    /// view's own answer.
    func testOverTheContent_aClickStillFindsTheViewsUnderTheDropView() throws {
        let host = try mount(.overTheContent)
        try focusFirstField(in: host)

        for point in [Self.pointOnRecipientField, Self.pointOnTextEditor, Self.pointOnEmptySpace] {
            let hit = host.hitView(at: point)
            XCTAssertNotNil(hit, "\(point)")
            XCTAssertFalse(hit is MacDraftFileDropView, "\(point)")
        }
        XCTAssertTrue(host.hitView(at: Self.pointOnTextEditor) is NSTextView)
    }

    // MARK: - What the drop view does with a drag

    /// Revert-check: deleting the `MacDraftFileDropTarget` from `View.macDraftFileDropOverlay`
    /// makes this fail.
    func testOverTheContent_aDropOfFiles_isHandedToTheSheet() throws {
        let recorder = Recorder()
        let host = try mount(.overTheContent, recorder: recorder)
        let dropView = try XCTUnwrap(host.first(MacDraftFileDropView.self))
        let files = [URL(fileURLWithPath: "/tmp/One.pdf"), URL(fileURLWithPath: "/tmp/Two.png")]
        let drag = FakeDraggingInfo.files(files, in: host.window, at: Self.pointOnTextEditor)

        XCTAssertEqual(dropView.draggingEntered(drag), .copy)
        XCTAssertTrue(dropView.performDragOperation(drag))

        XCTAssertEqual(recorder.dropped, [files])
    }

    /// A sheet that takes no files, Forward, refuses the drag before the drop, over its text
    /// editor too.
    ///
    /// Revert-check: passing `acceptsFiles: { true }` to the `MacDraftFileDropTarget` in
    /// `View.macDraftFileDropOverlay` makes this fail.
    func testOverTheContent_aSheetThatTakesNoFiles_refusesTheDrag() throws {
        let recorder = Recorder()
        recorder.accepts = false
        let host = try mount(.overTheContent, recorder: recorder)
        let dropView = try XCTUnwrap(host.first(MacDraftFileDropView.self))
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: host.window,
            at: Self.pointOnTextEditor
        )

        XCTAssertEqual(dropView.draggingEntered(drag), [])
        XCTAssertFalse(dropView.performDragOperation(drag))
        XCTAssertEqual(recorder.dropped, [])
    }
}
#endif
