#if os(macOS)
import AppKit
import CoreData
import SwiftUI
import WebKit
import XCTest
@testable import esc_chatmail

/// A file dropped on the Mac's chat (`View.macDraftFileDrop`, `MacDraftFileDropView`), and the
/// two views in front of the chat that hand a file drag to it instead of taking it themselves
/// (`MacFileDropForwarder`): the reply field's text view and an email's web view. Mac only, so
/// it runs in `Mac.xctestplan`.
///
/// HONEST SCOPE: the views are mounted in a window that is never shown, and each is handed a
/// drag directly (`FakeDraggingInfo`), which is what AppKit does once it has chosen a view. No
/// file is dragged and no test asks AppKit which view it would choose: that was measured once,
/// through AppKit's private hit test, and is written down in `docs/mac-app-plan.md` ("Files").
/// So these pin what each view does with a drag it is given, not that it is given it, and
/// nothing here has been seen in the app. One term of the drop view's answer is not run here
/// either: that its window has a sheet attached, which would mean presenting one. The rule
/// for it is `DraftFileDropPolicyTests`'; that the view reads `attachedSheet` is not pinned.
@MainActor
final class MacDraftFileDropViewTests: XCTestCase {
    // MARK: - The drop view

    /// Revert-check: returning false from `MacDraftFileDropView.performDragOperation` without
    /// calling `onDropFiles` makes this fail; returning `[]` from `operation(for:)` makes the
    /// first assertion fail.
    func testFileDrag_overTheChat_isACopy_andTheDropHandsOverTheFilesInOrder() throws {
        let harness = try Harness()
        let files = [URL(fileURLWithPath: "/tmp/One.pdf"), URL(fileURLWithPath: "/tmp/Two.png")]
        let drag = FakeDraggingInfo.files(files, in: harness.window)

        XCTAssertEqual(harness.dropView.draggingEntered(drag), .copy)
        XCTAssertEqual(harness.dropView.draggingUpdated(drag), .copy)
        XCTAssertTrue(harness.dropView.prepareForDragOperation(drag))
        XCTAssertTrue(harness.dropView.performDragOperation(drag))

        XCTAssertEqual(harness.model.drops.map { $0.map(\.path) }, [["/tmp/One.pdf", "/tmp/Two.png"]])
        harness.close()
    }

    /// The drop reports what the chat answered, so a drop the composer refuses slides back.
    ///
    /// Revert-check: returning true from `performDragOperation` whatever `onDropFiles`
    /// answers makes this fail.
    func testDrop_theChatRefuses_isNotTaken() throws {
        let harness = try Harness()
        harness.model.takesDrops = false
        let drag = FakeDraggingInfo.files([URL(fileURLWithPath: "/tmp/One.pdf")], in: harness.window)

        XCTAssertFalse(harness.dropView.performDragOperation(drag))
        XCTAssertEqual(harness.model.drops.count, 1)
        harness.close()
    }

    /// Revert-check: passing `acceptsFiles: true` in `operation(for:)` whatever the closure
    /// answers makes every assertion fail; dropping the `operation(for:)` guard from
    /// `performDragOperation` makes the last two fail.
    func testFileDrag_whileTheReplyCannotTakeFiles_isRefused_beforeAndAtTheDrop() throws {
        let harness = try Harness()
        harness.model.accepts = false
        let drag = FakeDraggingInfo.files([URL(fileURLWithPath: "/tmp/One.pdf")], in: harness.window)

        XCTAssertEqual(harness.dropView.draggingEntered(drag), [])
        XCTAssertEqual(harness.dropView.draggingUpdated(drag), [])
        XCTAssertFalse(harness.dropView.prepareForDragOperation(drag))
        XCTAssertFalse(harness.dropView.performDragOperation(drag))
        XCTAssertTrue(harness.model.drops.isEmpty)
        harness.close()
    }

    /// A send or an import can start between the drag coming in and the drop.
    func testDrop_afterTheReplyStoppedTakingFiles_isRefused() throws {
        let harness = try Harness()
        let drag = FakeDraggingInfo.files([URL(fileURLWithPath: "/tmp/One.pdf")], in: harness.window)
        XCTAssertEqual(harness.dropView.draggingEntered(drag), .copy)

        harness.model.accepts = false

        XCTAssertFalse(harness.dropView.performDragOperation(drag))
        XCTAssertTrue(harness.model.drops.isEmpty)
        harness.close()
    }

    /// Revert-check: passing `carriesFiles: true` in `operation(for:)` whatever the
    /// pasteboard holds makes the text drag fail; reading every URL (`options: [:]`) in
    /// `carriesFiles` makes the link fail.
    func testDrag_ofTextOrALink_isNotTheChats() throws {
        let harness = try Harness()
        let text = FakeDraggingInfo.text("Some words", in: harness.window)
        let link = FakeDraggingInfo(
            pasteboard: FakeDraggingInfo.pasteboard(
                holding: [try XCTUnwrap(NSURL(string: "https://example.com/a.pdf"))]
            ),
            window: harness.window
        )

        XCTAssertEqual(harness.dropView.draggingEntered(text), [])
        XCTAssertFalse(harness.dropView.performDragOperation(text))
        XCTAssertEqual(harness.dropView.draggingEntered(link), [])
        XCTAssertFalse(harness.dropView.performDragOperation(link))
        XCTAssertTrue(harness.model.drops.isEmpty)
        harness.close()
    }

    /// Revert-check: passing `sourceAllowsCopy: true` in `operation(for:)` whatever the
    /// source allows makes this fail.
    func testFileDrag_whoseSourceAllowsNoCopy_isRefused() throws {
        let harness = try Harness()
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: harness.window,
            sourceOperationMask: [.link]
        )

        XCTAssertEqual(harness.dropView.draggingEntered(drag), [])
        harness.close()
    }

    /// The drop view is behind the whole chat and must take no click from it.
    ///
    /// Revert-check: deleting the `hitTest(_:)` override from `MacDraftFileDropView` makes
    /// this fail.
    func testDropView_takesNoClicks() throws {
        let harness = try Harness()
        let inside = NSPoint(x: harness.dropView.bounds.midX, y: harness.dropView.bounds.midY)
        XCTAssertTrue(harness.dropView.bounds.contains(inside))

        XCTAssertNil(harness.dropView.hitTest(harness.dropView.convert(inside, to: harness.dropView.superview)))
        harness.close()
    }

    /// Revert-check: deleting `registerForDraggedTypes([.fileURL])` from the initializer
    /// makes this fail. Unregistered, AppKit never offers the view a drag at all.
    func testDropView_isRegisteredForFiles_andFillsTheChat() throws {
        let harness = try Harness()

        XCTAssertEqual(harness.dropView.registeredDraggedTypes, [.fileURL])
        XCTAssertEqual(harness.dropView.convert(harness.dropView.bounds, to: nil).size, Harness.size)
        harness.close()
    }

    // MARK: - Found by the views in front of it

    /// Revert-check: returning the drop view from `dropView(under:at:)` whether or not its
    /// frame holds the point makes the second assertion fail; returning nil for it always
    /// makes the first fail.
    func testDropViewLookup_findsTheChatUnderAPoint_andNothingOutsideIt() throws {
        let harness = try Harness(chatSize: CGSize(width: 200, height: 150))
        let frame = harness.dropView.convert(harness.dropView.bounds, to: nil)

        XCTAssertTrue(
            MacDraftFileDropView.dropView(in: harness.window, at: NSPoint(x: frame.midX, y: frame.midY))
                === harness.dropView
        )
        XCTAssertNil(
            MacDraftFileDropView.dropView(in: harness.window, at: NSPoint(x: frame.maxX + 20, y: frame.midY))
        )
        XCTAssertNil(MacDraftFileDropView.dropView(in: nil, at: .zero))
        harness.close()
    }

    // MARK: - The reply field

    /// A text view given a file types its path at the pointer. In a reply the file is
    /// attached instead, and the draft is left as it was.
    ///
    /// Revert-check: deleting the `draggingEntered`, `prepareForDragOperation` and
    /// `performDragOperation` overrides from `MacReplyTextView` makes this fail: the drop is
    /// not handed over and "/tmp/One.pdf" is typed into the draft.
    func testFileDrag_onTheReplyField_goesToTheChat_andTypesNothing() throws {
        let harness = try Harness(text: "Hello")
        let textView = try harness.replyTextView()
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: harness.window,
            at: textView.convert(NSPoint(x: 5, y: 5), to: nil)
        )

        XCTAssertEqual(textView.draggingEntered(drag), .copy)
        XCTAssertEqual(textView.draggingUpdated(drag), .copy)
        XCTAssertTrue(textView.prepareForDragOperation(drag))
        XCTAssertTrue(textView.performDragOperation(drag))
        textView.concludeDragOperation(drag)

        XCTAssertEqual(harness.model.drops.map { $0.map(\.path) }, [["/tmp/One.pdf"]])
        XCTAssertEqual(textView.string, "Hello")
        XCTAssertEqual(harness.model.text, "Hello")
        harness.close()
    }

    /// Revert-check: answering `nil` from `MacFileDropForwarder.draggingEntered` where it
    /// finds no drop view (so the text view takes the drag) makes this fail.
    func testFileDrag_onAReplyFieldWithNoChatBehindIt_isRefused_andTypesNothing() throws {
        let harness = try Harness(text: "Hello", hasDropView: false)
        let textView = try harness.replyTextView()
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: harness.window,
            at: textView.convert(NSPoint(x: 5, y: 5), to: nil)
        )

        XCTAssertEqual(textView.draggingEntered(drag), [])
        XCTAssertFalse(textView.prepareForDragOperation(drag))
        XCTAssertFalse(textView.performDragOperation(drag))
        textView.concludeDragOperation(drag)

        XCTAssertEqual(textView.string, "Hello")
        harness.close()
    }

    /// Revert-check: refusing where the forwarder answers nil (`?? []` in place of
    /// `?? super.draggingEntered(sender)`, and the same in `performDragOperation`) makes
    /// this fail.
    func testTextDrag_onTheReplyField_isStillTheTextViews() throws {
        let harness = try Harness(text: "")
        let textView = try harness.replyTextView()
        let drag = FakeDraggingInfo.text(
            "Dragged words",
            in: harness.window,
            at: textView.convert(NSPoint(x: 5, y: 5), to: nil)
        )

        XCTAssertNotEqual(textView.draggingEntered(drag), [])
        XCTAssertTrue(textView.prepareForDragOperation(drag))
        XCTAssertTrue(textView.performDragOperation(drag))
        textView.concludeDragOperation(drag)

        XCTAssertEqual(textView.string, "Dragged words")
        XCTAssertTrue(harness.model.drops.isEmpty)
        harness.close()
    }

    /// A drag that left is forgotten: the next drag, of text, is the text view's again.
    ///
    /// Revert-check: deleting `end()` from `MacFileDropForwarder.draggingExited` makes this
    /// fail: the text drag's update is answered as the file drag was.
    func testFileDrag_thatLeavesTheField_isForgotten() throws {
        let harness = try Harness(text: "")
        let textView = try harness.replyTextView()
        let at = textView.convert(NSPoint(x: 5, y: 5), to: nil)
        harness.model.accepts = false
        let files = FakeDraggingInfo.files([URL(fileURLWithPath: "/tmp/One.pdf")], in: harness.window, at: at)
        XCTAssertEqual(textView.draggingEntered(files), [])

        textView.draggingExited(files)

        let text = FakeDraggingInfo.text("Dragged words", in: harness.window, at: at)
        XCTAssertNotEqual(textView.draggingUpdated(text), [])
        harness.close()
    }

    // MARK: - An email's web view

    /// Revert-check: deleting the `draggingEntered` and `performDragOperation` overrides from
    /// `LayoutAwareWKWebView` makes this fail: WebKit takes the drop and nothing reaches the
    /// chat.
    func testFileDrag_onAnEmailCard_goesToTheChat() throws {
        let harness = try Harness(hasWebView: true)
        let webView = try harness.webView()
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: harness.window,
            at: webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        )

        XCTAssertEqual(webView.draggingEntered(drag), .copy)
        XCTAssertEqual(webView.draggingUpdated(drag), .copy)
        XCTAssertTrue(webView.prepareForDragOperation(drag))
        XCTAssertTrue(webView.performDragOperation(drag))
        webView.concludeDragOperation(drag)

        XCTAssertEqual(harness.model.drops.map { $0.map(\.path) }, [["/tmp/One.pdf"]])
        harness.close()
    }

    /// The reader's sheet has no chat behind it. A `WKWebView` given the file would load it in
    /// place of the email.
    ///
    /// Revert-check: deleting the drag overrides from `LayoutAwareWKWebView` makes this fail:
    /// WebKit answers the drag with a copy and takes the drop.
    func testFileDrag_onAWebViewWithNoChatBehindIt_isRefused() throws {
        let harness = try Harness(hasDropView: false, hasWebView: true)
        let webView = try harness.webView()
        let drag = FakeDraggingInfo.files(
            [URL(fileURLWithPath: "/tmp/One.pdf")],
            in: harness.window,
            at: webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        )

        XCTAssertEqual(webView.draggingEntered(drag), [])
        XCTAssertEqual(webView.draggingUpdated(drag), [])
        XCTAssertFalse(webView.prepareForDragOperation(drag))
        XCTAssertFalse(webView.performDragOperation(drag))
        webView.concludeDragOperation(drag)
        harness.close()
    }

    /// No drag reaches WebKit, with a chat behind the web view or without one.
    ///
    /// Revert-check: answering with `super`'s where the forwarder answers nil (as
    /// `MacReplyTextView` does) makes this fail.
    func testTextOrLinkDrag_onAWebView_isRefused() throws {
        let harness = try Harness(hasWebView: true)
        let webView = try harness.webView()
        let at = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        let link = FakeDraggingInfo(
            pasteboard: FakeDraggingInfo.pasteboard(
                holding: [try XCTUnwrap(NSURL(string: "https://example.com/"))]
            ),
            window: harness.window,
            locationInWindow: at
        )

        XCTAssertEqual(webView.draggingEntered(link), [])
        XCTAssertFalse(webView.prepareForDragOperation(link))
        XCTAssertFalse(webView.performDragOperation(link))
        webView.concludeDragOperation(link)
        XCTAssertTrue(harness.model.drops.isEmpty)
        harness.close()
    }

    // MARK: - The import of a dropped file

    /// Why a drop's import does not ask for a security scope. In the Mac's sandbox a file URL
    /// that came from no picker opens none, so the pickers' rule refuses it before reading
    /// anything; told a scope is only taken if offered, the import goes on to read the file.
    ///
    /// The file is larger than a draft may hold, so the import that goes on stops at its size
    /// check and neither case writes anything: this host's attachment folder is the real
    /// app's.
    ///
    /// Revert-check: making `SecurityScope.ifOffered.allowsReading` answer
    /// `didStartAccessing` makes the second import report "could not be read" and this fail.
    func testImport_ofAFileWithNoSecurityScope_isRefusedForAPicker_andReadForADrop() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDraftFileDropViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Huge.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        // Sparse: 26 MB of size and no bytes on disk.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(DraftAttachmentImport.maximumTotalBytes) + 1024 * 1024)
        try handle.close()
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()

        var failuresByScope: [[String]] = []
        for scope in [DocumentAttachmentImporter.SecurityScope.required, .ifOffered] {
            var operation: Task<Void, Never>?
            var failures: [String] = []
            var attachments: [Attachment] = []
            DocumentAttachmentImporter(
                attachments: Binding(get: { attachments }, set: { attachments = $0 }),
                viewContext: context,
                onProcessingChanged: { _ in },
                onOperationChanged: { if let started = $0 { operation = started } },
                onImportFailures: { failures = $0 },
                registry: AttachmentAccountWorkRegistry(),
                securityScope: scope
            )
            .importDocuments(at: [url])
            let started = try XCTUnwrap(operation, "The import did not start")
            await started.value
            XCTAssertTrue(attachments.isEmpty)
            failuresByScope.append(failures)
        }

        XCTAssertEqual(
            failuresByScope.first,
            [DraftAttachmentImport.ImportError.unreadable(filename: "Huge.pdf").localizedDescription]
        )
        XCTAssertEqual(failuresByScope.last?.count, 1)
        XCTAssertTrue(
            failuresByScope.last?.first?.contains("would exceed the 25 MB") == true,
            "\(failuresByScope)"
        )
    }
}

// MARK: - Harness

private final class DropModel: ObservableObject {
    var text: String
    var accepts = true
    var takesDrops = true
    var drops: [[URL]] = []

    init(text: String) {
        self.text = text
    }
}

private struct StandInWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> LayoutAwareWKWebView {
        let webView = LayoutAwareWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // As a preview card's is.
        webView.makeNonInteractive()
        return webView
    }

    func updateNSView(_ webView: LayoutAwareWKWebView, context: Context) {}
}

/// A stand-in for the chat column: something in front (a web view, the real reply field) and
/// the real drop view behind, applied with the modifier `ChatView` uses.
private struct ChatStandIn: View {
    let model: DropModel
    let chatSize: CGSize
    let hasDropView: Bool
    let hasWebView: Bool

    var body: some View {
        let chat = VStack(spacing: 0) {
            if hasWebView {
                StandInWebView().frame(height: 60)
            }
            Spacer(minLength: 0)
            MacReplyTextField(
                text: Binding(get: { model.text }, set: { model.text = $0 }),
                fontSize: 13,
                maximumLineCount: 5,
                focusBridge: ReplyFieldFocusBridge(),
                canSend: { _ in true },
                onSend: {},
                onCancel: {}
            )
        }
        .frame(width: chatSize.width, height: chatSize.height)

        if hasDropView {
            chat.macDraftFileDrop(
                acceptsFiles: { model.accepts },
                onDropFiles: { urls in
                    model.drops.append(urls)
                    return model.takesDrops
                }
            )
        } else {
            chat
        }
    }
}

@MainActor
private final class Harness {
    nonisolated static let size = CGSize(width: 400, height: 300)

    let model: DropModel
    let window: NSWindow
    private let host: NSHostingView<ChatStandIn>
    private let foundDropView: MacDraftFileDropView?

    init(
        text: String = "",
        chatSize: CGSize = Harness.size,
        hasDropView: Bool = true,
        hasWebView: Bool = false
    ) throws {
        model = DropModel(text: text)
        window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: Self.size.width, height: Self.size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        host = NSHostingView(
            rootView: ChatStandIn(
                model: model,
                chatSize: chatSize,
                hasDropView: hasDropView,
                hasWebView: hasWebView
            )
        )
        host.frame = NSRect(origin: .zero, size: Self.size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // SwiftUI builds its AppKit views on a later turn of the run loop.
        let deadline = Date().addingTimeInterval(5)
        while Self.first(MacReplyTextView.self, in: host) == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
        foundDropView = Self.first(MacDraftFileDropView.self, in: host)
        if hasDropView {
            _ = try XCTUnwrap(foundDropView, "The drop view was not built")
        } else {
            XCTAssertNil(foundDropView)
        }
    }

    var dropView: MacDraftFileDropView {
        // Checked in `init` wherever a test asked for one.
        foundDropView!
    }

    func replyTextView() throws -> MacReplyTextView {
        try XCTUnwrap(Self.first(MacReplyTextView.self, in: host), "The field's text view was not built")
    }

    func webView() throws -> LayoutAwareWKWebView {
        try XCTUnwrap(Self.first(LayoutAwareWKWebView.self, in: host), "The web view was not built")
    }

    func close() {
        window.contentView = nil
        window.close()
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = first(type, in: subview) { return match }
        }
        return nil
    }
}
#endif
