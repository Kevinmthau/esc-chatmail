import XCTest
@testable import esc_chatmail

/// The wiring that gives an attachment in a Mac chat its menu, which only source shows: both
/// of the views that draw a message's attachments put the menu on each one, and the menu
/// changes nothing on iOS (`docs/mac-app-plan.md`, "Files").
///
/// HONEST SCOPE: this reads source text, as `ChatFileDropSourceTests` does, so it runs in the
/// iOS suite although the menu is the Mac's. It pins that each view asks for the menu and with
/// which attachments. What the menu is and does is `MacAttachmentExportMenuTests`' to pin, on
/// a stand-in view, and it has not been seen in the app.
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

    /// The menu goes on each cell: on the grid it would be one menu with no clicked
    /// attachment.
    ///
    /// Revert-check: deleting the `.macAttachmentExportMenu(` modifier from the `ForEach` in
    /// `AttachmentGrid` makes this fail.
    func testGrid_hasTheMenuOnEachCell_overAllOfItsAttachments() throws {
        let source = try String(
            contentsOf: repoFile("esc-chatmail/Views/Components/Attachments/AttachmentGrid.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "                    onTap: { onTap(attachment) }\n"
                + "                )\n"
                + "                // On the cell, not the grid: the menu is the clicked attachment's.\n"
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

    private func repoFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
