import XCTest
@testable import esc_chatmail

/// The wiring that gives an attachment in a Mac chat its menu and lets it be dragged out,
/// which only source shows: both of the views that draw a message's attachments put the two
/// on each one, and neither changes anything on iOS (`docs/mac-app-plan.md`, "Files").
///
/// HONEST SCOPE: this reads source text, as `ChatFileDropSourceTests` does, so it runs in the
/// iOS suite although the menu and the drag are the Mac's. It pins that each view asks for
/// them, in which order and with which attachments. What they are and do is
/// `MacAttachmentExportMenuTests`' and `MacAttachmentDragSourceViewTests`' to pin, on stand-in
/// views, and neither has been seen in the app.
final class AttachmentExportSourceTests: XCTestCase {
    /// Revert-check: deleting the `.macAttachmentExportMenu(` modifier from
    /// `AttachmentGridView` makes this fail: a message's only attachment opens the message's
    /// menu, which has no Save.
    func testSingleAttachment_hasTheMenu_overTheAttachmentsTheMessageShows() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Components/AttachmentGridView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "                .macAttachmentExportMenu(\n"
                + "                    attachment: attachment,\n"
                + "                    shownAttachments: resolvedAttachments,\n"
        ))
        XCTAssertEqual(source.components(separatedBy: ".macAttachmentExportMenu(").count, 2)
    }

    /// The drag source takes the attachment's clicks, so it must hand them to the same Quick
    /// Look the attachment's own button opens. And it goes on before the menu: the menu's view
    /// must contain it, or a right-click on the drag source finds no menu behind it.
    ///
    /// Revert-check: deleting the `.macAttachmentDragSource(` modifier from
    /// `AttachmentGridView` makes this fail, and so does moving it after
    /// `.macAttachmentExportMenu(`.
    func testSingleAttachment_canBeDraggedOut_andItsDragSourceIsInsideItsMenu() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Components/AttachmentGridView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "                .macAttachmentDragSource(\n"
                + "                    attachment: attachment,\n"
                + "                    onClick: {\n"
                + "                        presentQuickLook(\n"
                + "                            for: attachment,\n"
                + "                            in: resolvedAttachments\n"
                + "                        )\n"
                + "                    }\n"
                + "                )\n"
                + "                .macAttachmentExportMenu(\n"
        ))
        XCTAssertEqual(source.components(separatedBy: ".macAttachmentDragSource(").count, 2)
    }

    /// The menu goes on each cell: on the grid it would be one menu with no clicked
    /// attachment.
    ///
    /// Revert-check: deleting the `.macAttachmentExportMenu(` modifier from the `ForEach` in
    /// `AttachmentGrid` makes this fail, and so does deleting `.macAttachmentDragSource(` or
    /// moving it after the menu.
    func testGrid_hasTheDragSourceAndTheMenuOnEachCell_overAllOfItsAttachments() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Components/Attachments/AttachmentGrid.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "                    onTap: { onTap(attachment) }\n"
                + "                )\n"
                + "                // On the cell, not the grid: the drag and the menu are the clicked attachment's.\n"
                + "                .macAttachmentDragSource(\n"
                + "                    attachment: attachment,\n"
                + "                    onClick: { onTap(attachment) }\n"
                + "                )\n"
                + "                .macAttachmentExportMenu(\n"
                + "                    attachment: attachment,\n"
                + "                    shownAttachments: attachments,\n"
                + "                    onQuickLook: { onTap(attachment) }\n"
                + "                )\n"
        ))
    }

    /// Revert-check: applying the modifier outside the `#if os(macOS)` branch of
    /// `macAttachmentExportMenu` makes this fail. On iOS the attachment's view is returned as
    /// it is, so a long press on it still opens the message's menu.
    func testTheMenu_isTheMacsAlone() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Platform/View+MacAttachmentExportMenu.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "        #if os(macOS)\n"
                + "        modifier(\n"
                + "            MacAttachmentExportMenu(\n"
        ))
        XCTAssertTrue(source.contains(
            "        #else\n"
                + "        self\n"
                + "        #endif\n"
        ))
    }

    /// Revert-check: putting the drag source over every attachment (deleting
    /// `if attachment.isReady`) makes this fail, and so does adding it outside the
    /// `#if os(macOS)` branch.
    func testTheDragSource_isTheMacsAlone_andOnlyOverAnAttachmentWithItsFile() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Platform/View+MacAttachmentDragSource.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "        #if os(macOS)\n"
                + "        overlay {\n"
                + "            if attachment.isReady {\n"
                + "                MacAttachmentDragSource(\n"
        ))
        XCTAssertTrue(source.contains(
            "        #else\n"
                + "        self\n"
                + "        #endif\n"
        ))
    }

    private func repoFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
