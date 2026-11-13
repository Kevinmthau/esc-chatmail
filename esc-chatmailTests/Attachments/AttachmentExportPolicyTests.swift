import XCTest
@testable import esc_chatmail

/// The menu of an attachment in a Mac chat and the name a saved attachment is given
/// (`AttachmentExportPolicy`; `docs/mac-app-plan.md`, "Files"). Pure, so it runs on both
/// platforms.
final class AttachmentExportPolicyTests: XCTestCase {
    private typealias Policy = AttachmentExportPolicy

    private func entries(isReady: Bool, readyCount: Int, shownCount: Int) -> [String] {
        Policy.menu(isReady: isReady, readyCount: readyCount, shownCount: shownCount).map {
            "\(Policy.title(for: $0.item)):\($0.isEnabled ? "on" : "off")"
        }
    }

    // MARK: - The menu

    /// Revert-check: appending `.saveAll` whatever `shownCount` is makes this fail. One
    /// attachment has nothing for Save All to add.
    func testMenu_oneAttachment_hasQuickLookAndSave_andNoSaveAll() {
        XCTAssertEqual(
            entries(isReady: true, readyCount: 1, shownCount: 1),
            ["Quick Look:on", "Save Attachment…:on"]
        )
    }

    /// Revert-check: returning `(.save, true)` whatever `isReady` is makes this fail. An
    /// attachment still downloading has no file to save, and its menu keeps its entries.
    func testMenu_anAttachmentWithoutItsFile_keepsItsEntries_disabled() {
        XCTAssertEqual(
            entries(isReady: false, readyCount: 0, shownCount: 1),
            ["Quick Look:off", "Save Attachment…:off"]
        )
    }

    /// Revert-check: enabling `.saveAll` on `isReady` in place of `readyCount > 0` makes the
    /// second assertion fail. Save All is for the message, so it is on while any attachment
    /// has its file, the clicked one or not.
    func testMenu_severalAttachments_addSaveAll_enabledWhileAnyHasItsFile() {
        XCTAssertEqual(
            entries(isReady: true, readyCount: 3, shownCount: 3),
            ["Quick Look:on", "Save Attachment…:on", "Save All Attachments…:on"]
        )
        XCTAssertEqual(
            entries(isReady: false, readyCount: 2, shownCount: 3),
            ["Quick Look:off", "Save Attachment…:off", "Save All Attachments…:on"]
        )
        XCTAssertEqual(
            entries(isReady: false, readyCount: 0, shownCount: 2),
            ["Quick Look:off", "Save Attachment…:off", "Save All Attachments…:off"]
        )
    }

    func testMenu_saveAllCarriesTheNumberOfFilesItSaves() {
        let items = Policy.menu(isReady: true, readyCount: 2, shownCount: 5).map(\.item)
        XCTAssertEqual(items, [.quickLook, .save, .saveAll(count: 2)])
    }

    // MARK: - The saved file's name

    func testFilename_aPlainName_isKept() {
        XCTAssertEqual(Policy.filename(storedFilename: "Q3 report.pdf", sourceExtension: "pdf"), "Q3 report.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "IMG_0042.HEIC", sourceExtension: "jpg"), "IMG_0042.HEIC")
        XCTAssertEqual(Policy.filename(storedFilename: "résumé 履歴書.docx", sourceExtension: "docx"), "résumé 履歴書.docx")
    }

    /// Revert-check: taking the whole stored name in place of its last component makes this
    /// fail. A name from an email must not be able to say where the file goes.
    func testFilename_aPath_keepsOnlyItsLastComponent() {
        XCTAssertEqual(Policy.filename(storedFilename: "../../Library/x.plist", sourceExtension: "plist"), "x.plist")
        XCTAssertEqual(Policy.filename(storedFilename: "/etc/passwd", sourceExtension: "txt"), "passwd.txt")
        XCTAssertEqual(Policy.filename(storedFilename: "C:\\Users\\me\\tax.pdf", sourceExtension: "pdf"), "tax.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "folder/", sourceExtension: "pdf"), "folder.pdf")
    }

    /// Revert-check: deleting `.replacingOccurrences(of: ":", with: "-")` makes this fail.
    func testFilename_aColon_becomesAHyphen() {
        XCTAssertEqual(Policy.filename(storedFilename: "Call 10:30.txt", sourceExtension: "txt"), "Call 10-30.txt")
    }

    /// Revert-check: deleting the `directionScalars` check from `isRemoved` makes the first
    /// assertion fail, and deleting the `.control` case makes the second. A right-to-left
    /// override draws `invoice\u{202E}fdp.exe` as `invoiceexe.pdf`.
    func testFilename_directionAndControlCharacters_areRemoved() {
        XCTAssertEqual(
            Policy.filename(storedFilename: "invoice\u{202E}fdp.exe", sourceExtension: "exe"),
            "invoicefdp.exe"
        )
        XCTAssertEqual(
            Policy.filename(storedFilename: "a\u{0000}b\nc\td\u{2028}e.pdf", sourceExtension: "pdf"),
            "abcde.pdf"
        )
        XCTAssertEqual(
            Policy.filename(storedFilename: "\u{2066}x\u{2069}\u{200F}.pdf", sourceExtension: "pdf"),
            "x.pdf"
        )
    }

    /// A zero-width joiner is part of an emoji and of some scripts' spelling, so it stays.
    func testFilename_aJoinedEmoji_isKeptWhole() {
        let family = "👨\u{200D}👩\u{200D}👧"
        XCTAssertEqual(Policy.filename(storedFilename: "\(family).png", sourceExtension: "png"), "\(family).png")
    }

    /// Revert-check: deleting the `while name.hasPrefix(".")` loop makes this fail. A leading
    /// dot would hide the saved file.
    func testFilename_leadingDots_areRemoved() {
        XCTAssertEqual(Policy.filename(storedFilename: ".hidden.txt", sourceExtension: "txt"), "hidden.txt")
        XCTAssertEqual(Policy.filename(storedFilename: ".. .zshrc", sourceExtension: "txt"), "zshrc.txt")
    }

    /// Revert-check: deleting `name = fallbackBaseName` (the first) makes this fail.
    func testFilename_nothingUsable_isAttachmentWithTheFilesExtension() {
        XCTAssertEqual(Policy.filename(storedFilename: "", sourceExtension: "pdf"), "Attachment.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "   ", sourceExtension: "jpg"), "Attachment.jpg")
        XCTAssertEqual(Policy.filename(storedFilename: "..", sourceExtension: "png"), "Attachment.png")
        XCTAssertEqual(Policy.filename(storedFilename: "///", sourceExtension: ""), "Attachment")
        XCTAssertEqual(Policy.filename(storedFilename: "\u{202E}", sourceExtension: "pdf"), "Attachment.pdf")
    }

    /// Revert-check: appending the extension only where the name is empty makes this fail. A
    /// name with no extension gets the file's own, so the saved file opens.
    func testFilename_aNameWithoutAnExtension_getsTheFilesOwn() {
        XCTAssertEqual(Policy.filename(storedFilename: "scan", sourceExtension: "pdf"), "scan.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "scan.", sourceExtension: "pdf"), "scan.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "report v1.2 final", sourceExtension: "pdf"), "report v1.2 final.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "scan", sourceExtension: ""), "scan")
        // The extension is the app's own, made from the type, but it is not trusted either.
        XCTAssertEqual(Policy.filename(storedFilename: "scan", sourceExtension: "p/d.f"), "scan.pdf")
    }

    func testFilename_aNameWithAnExtension_keepsIt_whateverTheFileHas() {
        XCTAssertEqual(Policy.filename(storedFilename: "photo.jpeg", sourceExtension: "jpg"), "photo.jpeg")
        XCTAssertEqual(Policy.filename(storedFilename: "archive.tar.gz", sourceExtension: "bin"), "archive.tar.gz")
    }

    /// Revert-check: returning `name` from `truncated` makes this fail. A file name can be 255
    /// bytes; a longer one cannot be saved at all.
    func testFilename_aVeryLongName_isShortenedBeforeItsExtension() {
        let long = String(repeating: "a", count: 400) + ".pdf"
        let name = Policy.filename(storedFilename: long, sourceExtension: "pdf")
        XCTAssertEqual(name.utf8.count, Policy.maximumFilenameUTF8Count)
        XCTAssertTrue(name.hasSuffix(".pdf"))

        // Cut between characters, never inside one.
        let wide = String(repeating: "語", count: 200) + ".pdf"
        let wideName = Policy.filename(storedFilename: wide, sourceExtension: "pdf")
        XCTAssertLessThanOrEqual(wideName.utf8.count, Policy.maximumFilenameUTF8Count)
        XCTAssertGreaterThan(wideName.utf8.count, Policy.maximumFilenameUTF8Count - 4)
        XCTAssertTrue(wideName.hasSuffix(".pdf"))
        XCTAssertEqual(wideName.dropLast(4).filter { $0 != "語" }.count, 0)
    }

    func testSplitExtension_onlyLettersAndDigitsAfterTheLastDotAreAnExtension() {
        XCTAssertEqual(Policy.splitExtension(of: "a.pdf").base, "a")
        XCTAssertEqual(Policy.splitExtension(of: "a.pdf").pathExtension, "pdf")
        XCTAssertEqual(Policy.splitExtension(of: "a.tar.gz").base, "a.tar")
        XCTAssertEqual(Policy.splitExtension(of: "a.tar.gz").pathExtension, "gz")
        XCTAssertEqual(Policy.splitExtension(of: "v1.2 final").pathExtension, "")
        XCTAssertEqual(Policy.splitExtension(of: "name.").pathExtension, "")
        XCTAssertEqual(Policy.splitExtension(of: "name").pathExtension, "")
        XCTAssertEqual(Policy.splitExtension(of: "a." + String(repeating: "x", count: 17)).pathExtension, "")
    }

    // MARK: - A name that is free

    /// Revert-check: returning `name` from `availableFilename` whatever `isTaken` says makes
    /// this fail. Save All never replaces a file in the folder.
    func testAvailableFilename_aTakenName_getsTheFirstFreeNumberBeforeItsExtension() {
        XCTAssertEqual(Policy.availableFilename("Photo.jpg") { _ in false }, "Photo.jpg")
        XCTAssertEqual(Policy.availableFilename("Photo.jpg") { $0 == "Photo.jpg" }, "Photo 2.jpg")
        let taken: Set<String> = ["Photo.jpg", "Photo 2.jpg", "Photo 3.jpg"]
        XCTAssertEqual(Policy.availableFilename("Photo.jpg") { taken.contains($0) }, "Photo 4.jpg")
        XCTAssertEqual(Policy.availableFilename("notes") { $0 == "notes" }, "notes 2")
        XCTAssertEqual(Policy.availableFilename("a.tar.gz") { $0 == "a.tar.gz" }, "a.tar 2.gz")
    }

    // MARK: - Words

    func testFolderPrompt_countsItsAttachments() {
        XCTAssertEqual(Policy.folderPrompt(count: 1), "Choose a folder for 1 attachment.")
        XCTAssertEqual(Policy.folderPrompt(count: 4), "Choose a folder for 4 attachments.")
    }

    func testFailureTitle_saysOneOrSeveral() {
        XCTAssertEqual(Policy.failureTitle(failureCount: 1), "Attachment Not Saved")
        XCTAssertEqual(Policy.failureTitle(failureCount: 2), "Some Attachments Weren’t Saved")
    }
}
