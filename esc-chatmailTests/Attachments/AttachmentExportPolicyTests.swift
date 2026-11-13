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

    /// A "/" with a combining scalar after it is one `Character` that is not "/". Found in
    /// review of PR 406: split on `Character`s, `Library/\u{200D}evil.plist` came out whole,
    /// and Save All wrote it into a `Library` folder inside the folder the user chose.
    ///
    /// Revert-check: splitting `storedFilename` itself (its `Character`s) in place of its
    /// unicode scalars makes this fail.
    func testFilename_aSeparatorJoinedToACombiningScalar_stillEndsTheFolder() {
        let names = [
            "Library/\u{200D}evil.plist",
            "Library/\u{0301}evil.plist",
            "Library\\\u{FE0F}evil.plist",
            "a/\u{200D}b/\u{0301}c/\u{FE0F}evil.plist"
        ]
        for stored in names {
            let name = Policy.filename(storedFilename: stored, sourceExtension: "plist")
            XCTAssertFalse(name.unicodeScalars.contains("/"), name.debugDescription)
            XCTAssertFalse(name.unicodeScalars.contains("\\"), name.debugDescription)
            XCTAssertFalse(name.contains("Library"), name.debugDescription)
            XCTAssertTrue(name.hasSuffix("evil.plist"), name.debugDescription)
            XCTAssertEqual(URL(fileURLWithPath: "/chosen").appendingPathComponent(name).pathComponents.count, 3)
        }
    }

    /// Revert-check: replacing the colon with `replacingOccurrences(of:with:)` on the string,
    /// or not at all, makes this fail: the first leaves `:\u{0301}` as it is.
    func testFilename_aColon_becomesAHyphen() {
        XCTAssertEqual(Policy.filename(storedFilename: "Call 10:30.txt", sourceExtension: "txt"), "Call 10-30.txt")
        XCTAssertEqual(Policy.filename(storedFilename: "a:\u{0301}b.txt", sourceExtension: "txt"), "a-\u{0301}b.txt")
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

    /// Revert-check: deleting the `while name.unicodeScalars.first == "."` loop makes this
    /// fail, and testing `name.hasPrefix(".")` in its place makes the last assertion fail: a
    /// dot with an accent on it is not the `Character` ".", and the file's first byte is still
    /// a dot. A leading dot would hide the saved file.
    func testFilename_leadingDots_areRemoved() {
        XCTAssertEqual(Policy.filename(storedFilename: ".hidden.txt", sourceExtension: "txt"), "hidden.txt")
        XCTAssertEqual(Policy.filename(storedFilename: ".. .zshrc", sourceExtension: "txt"), "zshrc.txt")
        let accented = Policy.filename(storedFilename: ".\u{0301}hidden.txt", sourceExtension: "txt")
        XCTAssertNotEqual(accented.utf8.first, UInt8(ascii: "."))
        XCTAssertTrue(accented.hasSuffix("hidden.txt"))
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

    /// The download names the stored file after whatever follows the name's last dot, so
    /// adding that to the name again doubles it. Found in review of PR 406.
    ///
    /// Revert-check: deciding with `splitExtension(of: name).pathExtension.isEmpty` in place of
    /// `hasSuffixAfterDot` makes the first two fail (`main.c++.c`, `notes.txt~.txt`); deleting
    /// the `unknownTypeExtension` term makes the third (`Makefile.dat`).
    func testFilename_aNameThatEndsInSomethingAfterADot_orAFileOfNoKnownType_getsNothingAdded() {
        XCTAssertEqual(Policy.filename(storedFilename: "main.c++", sourceExtension: "c++"), "main.c++")
        XCTAssertEqual(Policy.filename(storedFilename: "notes.txt~", sourceExtension: "txt~"), "notes.txt~")
        XCTAssertEqual(Policy.unknownTypeExtension, "dat")
        XCTAssertEqual(Policy.filename(storedFilename: "Makefile", sourceExtension: "dat"), "Makefile")
    }

    func testHasSuffixAfterDot() {
        XCTAssertTrue(Policy.hasSuffixAfterDot("a.pdf"))
        XCTAssertTrue(Policy.hasSuffixAfterDot("main.c++"))
        XCTAssertTrue(Policy.hasSuffixAfterDot("notes.txt~"))
        XCTAssertFalse(Policy.hasSuffixAfterDot("scan"))
        XCTAssertFalse(Policy.hasSuffixAfterDot("scan."))
        XCTAssertFalse(Policy.hasSuffixAfterDot("report v1.2 final"))
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

        // One `Character` longer than any name may be: a letter under 300 accents. A cut
        // between `Character`s kept none of it and returned ".pdf", a hidden file.
        let stacked = "a" + String(repeating: "\u{0301}", count: 300) + ".pdf"
        let stackedName = Policy.filename(storedFilename: stacked, sourceExtension: "pdf")
        XCTAssertLessThanOrEqual(stackedName.utf8.count, Policy.maximumFilenameUTF8Count)
        XCTAssertEqual(stackedName.unicodeScalars.first, "a")
        XCTAssertTrue(stackedName.hasSuffix(".pdf"))
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
