import XCTest
@testable import esc_chatmail

/// The wiring that carries a file dropped on the Mac's New Message sheet to its draft's
/// attachments, which only source shows: the sheet has the drop view over it, the view model
/// holds the request, and the input bar imports it (`docs/mac-app-plan.md`, "Files").
///
/// HONEST SCOPE: this reads source text, as `ChatFileDropSourceTests` does for the chat, so it
/// runs in the iOS suite and in CI although the drop is the Mac's. It pins that each link is
/// there and matches its spelling. What each link does is `DraftFileDropPolicyTests`',
/// `ComposeViewModelTests`' and `MacComposeFileDropOverlayTests`' to pin, and no file has
/// been dropped in the app.
final class ComposeFileDropSourceTests: XCTestCase {
    /// Revert-check: deleting the `.macDraftFileDropOverlay(` modifier from `ComposeView`
    /// makes this fail. Without it New Message takes no dropped file, and a file dropped on
    /// the Forward sheet's message is typed into it as a path.
    func testSheet_hasTheDropViewOverIt_andAsksItsViewModel() throws {
        let source = try source("esc-chatmail/Views/Compose/ComposeView.swift")
        let modifier = try XCTUnwrap(source.range(of: "        .macDraftFileDropOverlay(\n"))
        let end = try XCTUnwrap(source.range(of: "\n        )\n", range: modifier.upperBound..<source.endIndex))
        let call = String(source[modifier.lowerBound..<end.upperBound])

        XCTAssertTrue(call.contains("viewModel.acceptsDroppedFiles"), call)
        XCTAssertTrue(call.contains("viewModel.receiveDroppedFiles(urls)"), call)
    }

    /// Behind the sheet's content, as the chat has its drop view, a field with the caret and
    /// the Forward sheet's text editor take a dropped file themselves
    /// (`MacComposeFileDropOverlayTests`).
    ///
    /// Revert-check: changing the modifier on `ComposeView` to `.macDraftFileDrop(` makes this
    /// fail.
    func testSheet_doesNotPutTheDropViewBehindItsContent() throws {
        let source = try source("esc-chatmail/Views/Compose/ComposeView.swift")

        XCTAssertFalse(source.contains(".macDraftFileDrop("))
        XCTAssertEqual(source.components(separatedBy: ".macDraftFileDropOverlay(").count, 2)
    }

    /// The overlay covers every control of the sheet. AppKit's hit test skips the drop view
    /// by itself; SwiftUI's has to be told.
    ///
    /// Revert-check: deleting `.allowsHitTesting(false)` from `View.macDraftFileDropOverlay`
    /// makes this fail.
    func testOverlay_isLeftOutOfSwiftUIsHitTesting() throws {
        let source = try source("esc-chatmail/Platform/View+MacDraftFileDrop.swift")
        let overlay = try XCTUnwrap(source.range(of: "        overlay {\n"))
        let end = try XCTUnwrap(source.range(of: "\n        }\n", range: overlay.upperBound..<source.endIndex))
        let body = String(source[overlay.upperBound..<end.lowerBound])

        XCTAssertTrue(body.contains("MacDraftFileDropTarget(acceptsFiles: acceptsFiles, onDropFiles: onDropFiles)"), body)
        XCTAssertTrue(body.contains(".allowsHitTesting(false)"), body)
    }

    /// The bar takes a request once: it clears the request before it imports, so a view
    /// update between the two cannot start the import again, and it clears it only where it
    /// goes on to import it.
    ///
    /// Revert-check: deleting `viewModel.pendingFileDrop = nil` from
    /// `ComposeInputBar.importPendingFileDropIfIdle` makes this fail, and so does moving it
    /// above the guard.
    func testInputBar_clearsTheRequestBeforeItImports_andOnlyThen() throws {
        let function = try inputBarFunction(named: "importPendingFileDropIfIdle")

        let guardRange = try XCTUnwrap(function.range(of: "guard DraftFileDropPolicy.startsImport("))
        let clear = try XCTUnwrap(function.range(of: "viewModel.pendingFileDrop = nil"))
        let importCall = try XCTUnwrap(function.range(of: "importDroppedFiles(drop)"))
        XCTAssertLessThan(guardRange.lowerBound, clear.lowerBound)
        XCTAssertLessThan(clear.lowerBound, importCall.lowerBound)
    }

    /// Revert-check: deleting either `onChange` that calls `importPendingFileDropIfIdle` from
    /// `ComposeInputBar.body` makes this fail: without the first a drop is never imported,
    /// and without the second one that arrived during an import waits for good.
    func testInputBar_looksForADropWhenOneArrives_andWhenAnImportEnds() throws {
        let source = try source("esc-chatmail/Views/Compose/ComposeInputBar.swift")

        XCTAssertTrue(source.contains(
            "        .onChange(of: viewModel.pendingFileDrop, initial: true) { _, _ in\n"
                + "            importPendingFileDropIfIdle()\n"
        ))
        XCTAssertTrue(source.contains(
            "        .onChange(of: viewModel.isImportingAttachments) { _, _ in\n"
                + "            importPendingFileDropIfIdle()\n"
        ))
    }

    /// A dropped file opens no security scope in the sandbox, and an import that requires
    /// one refuses every drop.
    ///
    /// Revert-check: deleting `securityScope: .ifOffered` from
    /// `ComposeInputBar.importDroppedFiles` makes this fail.
    func testInputBar_importsADropWithoutRequiringASecurityScope() throws {
        let function = try inputBarFunction(named: "importDroppedFiles")

        XCTAssertTrue(function.contains("securityScope: .ifOffered"), function)
        XCTAssertTrue(function.contains(".importDocuments(at: drop.fileURLs)"), function)
    }

    // MARK: - Source

    /// The text of one of `ComposeInputBar`'s private functions, to the next one.
    private func inputBarFunction(named name: String) throws -> String {
        let source = try source("esc-chatmail/Views/Compose/ComposeInputBar.swift")
        let start = try XCTUnwrap(
            source.range(of: "    private func \(name)("),
            "ComposeInputBar has no \(name)"
        )
        let end = source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex)?.upperBound
            ?? source.endIndex
        return String(source[start.lowerBound..<end])
    }

    private func source(_ relativePath: String) throws -> String {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
