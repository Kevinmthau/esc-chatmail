import XCTest
@testable import esc_chatmail

/// The menu of an attachment in a Mac chat and the name a saved attachment is given
/// (`AttachmentExportPolicy`; `docs/mac-app-plan.md`, "Files"). Pure, so it runs on both
/// platforms.
final class AttachmentExportPolicyTests: XCTestCase {
    private typealias Policy = AttachmentExportPolicy

    private func entries(isReady: Bool, isOpenable: Bool = false, readyCount: Int, shownCount: Int) -> [String] {
        Policy.menu(isReady: isReady, isOpenable: isOpenable, readyCount: readyCount, shownCount: shownCount).map {
            "\(Policy.title(for: $0.item)):\($0.isEnabled ? "on" : "off")"
        }
    }

    // MARK: - The menu

    /// Open follows Quick Look, for a kind of file that is opened and no other, and like the
    /// other entries that need the file it waits for it.
    ///
    /// Revert-check: appending `.open` whatever `isOpenable` is makes the last assertion
    /// fail; enabling it whatever `isReady` is makes the second fail.
    func testMenu_aKindThatIsOpened_addsOpenAfterQuickLook_enabledOnceItHasItsFile() {
        XCTAssertEqual(
            entries(isReady: true, isOpenable: true, readyCount: 1, shownCount: 1),
            ["Quick Look:on", "Open:on", "Save Attachment…:on"]
        )
        XCTAssertEqual(
            entries(isReady: false, isOpenable: true, readyCount: 1, shownCount: 2),
            ["Quick Look:off", "Open:off", "Save Attachment…:off", "Save All Attachments…:on"]
        )
        XCTAssertEqual(
            entries(isReady: true, isOpenable: false, readyCount: 1, shownCount: 1),
            ["Quick Look:on", "Save Attachment…:on"]
        )
    }

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
        let items = Policy.menu(isReady: true, isOpenable: false, readyCount: 2, shownCount: 5).map(\.item)
        XCTAssertEqual(items, [.quickLook, .save, .saveAll(count: 2)])
    }

    // MARK: - The saved file's name

    func testFilename_aPlainName_isKept() {
        XCTAssertEqual(Policy.filename(storedFilename: "Q3 report.pdf", typeExtension: "pdf"), "Q3 report.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "IMG_0042.HEIC", typeExtension: "jpg"), "IMG_0042.HEIC")
        XCTAssertEqual(Policy.filename(storedFilename: "résumé 履歴書.docx", typeExtension: "docx"), "résumé 履歴書.docx")
    }

    /// Revert-check: taking the whole stored name in place of its last component makes this
    /// fail. A name from an email must not be able to say where the file goes.
    func testFilename_aPath_keepsOnlyItsLastComponent() {
        XCTAssertEqual(Policy.filename(storedFilename: "../../Library/x.plist", typeExtension: "plist"), "x.plist")
        XCTAssertEqual(Policy.filename(storedFilename: "/etc/passwd", typeExtension: "txt"), "passwd.txt")
        XCTAssertEqual(Policy.filename(storedFilename: "C:\\Users\\me\\tax.pdf", typeExtension: "pdf"), "tax.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "folder/", typeExtension: "pdf"), "folder.pdf")
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
            let name = Policy.filename(storedFilename: stored, typeExtension: "plist")
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
        XCTAssertEqual(Policy.filename(storedFilename: "Call 10:30.txt", typeExtension: "txt"), "Call 10-30.txt")
        XCTAssertEqual(Policy.filename(storedFilename: "a:\u{0301}b.txt", typeExtension: "txt"), "a-\u{0301}b.txt")
    }

    /// Revert-check: deleting the `directionScalars` check from `isRemoved` makes the first
    /// assertion fail, and deleting the `.control` case makes the second. A right-to-left
    /// override draws `invoice\u{202E}fdp.exe` as `invoiceexe.pdf`.
    func testFilename_directionAndControlCharacters_areRemoved() {
        XCTAssertEqual(
            Policy.filename(storedFilename: "invoice\u{202E}fdp.exe", typeExtension: "exe"),
            "invoicefdp.exe"
        )
        XCTAssertEqual(
            Policy.filename(storedFilename: "a\u{0000}b\nc\td\u{2028}e.pdf", typeExtension: "pdf"),
            "abcde.pdf"
        )
        XCTAssertEqual(
            Policy.filename(storedFilename: "\u{2066}x\u{2069}\u{200F}.pdf", typeExtension: "pdf"),
            "x.pdf"
        )
    }

    /// A zero-width joiner is part of an emoji and of some scripts' spelling, so it stays.
    func testFilename_aJoinedEmoji_isKeptWhole() {
        let family = "👨\u{200D}👩\u{200D}👧"
        XCTAssertEqual(Policy.filename(storedFilename: "\(family).png", typeExtension: "png"), "\(family).png")
    }

    /// Revert-check: deleting the `while name.unicodeScalars.first == "."` loop makes this
    /// fail, and testing `name.hasPrefix(".")` in its place makes the last assertion fail: a
    /// dot with an accent on it is not the `Character` ".", and the file's first byte is still
    /// a dot. A leading dot would hide the saved file.
    func testFilename_leadingDots_areRemoved() {
        XCTAssertEqual(Policy.filename(storedFilename: ".hidden.txt", typeExtension: "txt"), "hidden.txt")
        XCTAssertEqual(Policy.filename(storedFilename: ".. .zshrc", typeExtension: "txt"), "zshrc.txt")
        let accented = Policy.filename(storedFilename: ".\u{0301}hidden.txt", typeExtension: "txt")
        XCTAssertNotEqual(accented.utf8.first, UInt8(ascii: "."))
        XCTAssertTrue(accented.hasSuffix("hidden.txt"))
    }

    /// Revert-check: deleting `name = fallbackBaseName` (the first) makes this fail.
    func testFilename_nothingUsable_isAttachmentWithTheFilesExtension() {
        XCTAssertEqual(Policy.filename(storedFilename: "", typeExtension: "pdf"), "Attachment.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "   ", typeExtension: "jpg"), "Attachment.jpg")
        XCTAssertEqual(Policy.filename(storedFilename: "..", typeExtension: "png"), "Attachment.png")
        XCTAssertEqual(Policy.filename(storedFilename: "///", typeExtension: ""), "Attachment")
        XCTAssertEqual(Policy.filename(storedFilename: "\u{202E}", typeExtension: "pdf"), "Attachment.pdf")
    }

    /// Revert-check: appending the extension only where the name is empty makes this fail. A
    /// name with no extension gets its type's, so the saved file opens.
    func testFilename_aNameWithoutAnExtension_getsItsTypes() {
        XCTAssertEqual(Policy.filename(storedFilename: "scan", typeExtension: "pdf"), "scan.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "scan.", typeExtension: "pdf"), "scan.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "report v1.2 final", typeExtension: "pdf"), "report v1.2 final.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "scan", typeExtension: ""), "scan")
        // The extension is the app's own, made from the type, but it is not trusted either.
        XCTAssertEqual(Policy.filename(storedFilename: "scan", typeExtension: "p/d.f"), "scan.pdf")
    }

    /// Digits after a name's last dot are a time, a date or a version far more often than a
    /// type. Read as an extension they left the saved file with none: a screenshot named for
    /// the time it was taken was saved as `Screen Shot at 1.02.33`, which nothing opens.
    /// Found in review of PR 408.
    ///
    /// Revert-check: deleting the all-digits term from the guard in `splitExtension` makes the
    /// first three fail.
    func testFilename_aNameThatEndsInDigitsAfterADot_getsItsTypesExtension() {
        XCTAssertEqual(
            Policy.filename(storedFilename: "Screen Shot at 1.02.33", typeExtension: "png"),
            "Screen Shot at 1.02.33.png"
        )
        XCTAssertEqual(Policy.filename(storedFilename: "Report 2026.11.13", typeExtension: "pdf"), "Report 2026.11.13.pdf")
        XCTAssertEqual(Policy.filename(storedFilename: "v2.0", typeExtension: "pdf"), "v2.0.pdf")
        // A digit beside a letter is a type, and an unknown type still adds nothing.
        XCTAssertEqual(Policy.filename(storedFilename: "song.mp3", typeExtension: "dat"), "song.mp3")
        XCTAssertEqual(Policy.filename(storedFilename: "backup.7z", typeExtension: "zip"), "backup.7z")
        XCTAssertEqual(Policy.filename(storedFilename: "archive.001", typeExtension: "dat"), "archive.001")
    }

    /// A name's own extension is kept and nothing is added to it, whatever characters it is
    /// made of, and a file of no known type gets nothing either. Found in review of PR 406.
    ///
    /// Revert-check: allowing only letters and digits in `splitExtension` makes the first two
    /// fail (`main.c++.txt`, `notes.txt~.txt`); deleting the `unknownTypeExtension` term from
    /// `filename` makes the last (`Makefile.dat`).
    func testFilename_aNameWithAnExtensionOfItsOwn_orAFileOfNoKnownType_getsNothingAdded() {
        XCTAssertEqual(Policy.filename(storedFilename: "main.c++", typeExtension: "txt"), "main.c++")
        XCTAssertEqual(Policy.filename(storedFilename: "notes.txt~", typeExtension: "txt"), "notes.txt~")
        XCTAssertEqual(Policy.unknownTypeExtension, "dat")
        XCTAssertEqual(Policy.filename(storedFilename: "Makefile", typeExtension: "dat"), "Makefile")
    }

    func testFilename_aNameWithAnExtension_keepsIt_whateverTheFileHas() {
        XCTAssertEqual(Policy.filename(storedFilename: "photo.jpeg", typeExtension: "jpg"), "photo.jpeg")
        XCTAssertEqual(Policy.filename(storedFilename: "archive.tar.gz", typeExtension: "bin"), "archive.tar.gz")
    }

    /// Revert-check: returning `name` from `truncated` makes this fail. A file name can be 255
    /// bytes; a longer one cannot be saved at all.
    func testFilename_aVeryLongName_isShortenedBeforeItsExtension() {
        let long = String(repeating: "a", count: 400) + ".pdf"
        let name = Policy.filename(storedFilename: long, typeExtension: "pdf")
        XCTAssertEqual(name.utf8.count, Policy.maximumFilenameUTF8Count)
        XCTAssertTrue(name.hasSuffix(".pdf"))

        // Cut between characters, never inside one.
        let wide = String(repeating: "語", count: 200) + ".pdf"
        let wideName = Policy.filename(storedFilename: wide, typeExtension: "pdf")
        XCTAssertLessThanOrEqual(wideName.utf8.count, Policy.maximumFilenameUTF8Count)
        XCTAssertGreaterThan(wideName.utf8.count, Policy.maximumFilenameUTF8Count - 4)
        XCTAssertTrue(wideName.hasSuffix(".pdf"))
        XCTAssertEqual(wideName.dropLast(4).filter { $0 != "語" }.count, 0)

        // One `Character` longer than any name may be: a letter under 300 accents. A cut
        // between `Character`s kept none of it and returned ".pdf", a hidden file.
        let stacked = "a" + String(repeating: "\u{0301}", count: 300) + ".pdf"
        let stackedName = Policy.filename(storedFilename: stacked, typeExtension: "pdf")
        XCTAssertLessThanOrEqual(stackedName.utf8.count, Policy.maximumFilenameUTF8Count)
        XCTAssertEqual(stackedName.unicodeScalars.first, "a")
        XCTAssertTrue(stackedName.hasSuffix(".pdf"))
    }

    /// The one rule for a name's extension, which everything that needs one asks: whether the
    /// type's is added, where `availableFilename` puts its number, what `truncated` keeps, and
    /// the type a dragged file is announced as. There were two, and `main.c++` had an
    /// extension for the first of those and none for the rest.
    ///
    /// Revert-check: each term of the guard in `splitExtension`, deleted alone, makes the
    /// assertion that names it fail.
    func testSplitExtension_isShort_hasNoSpace_andIsNotAllDigits() {
        func parts(_ name: String) -> [String] {
            let split = Policy.splitExtension(of: name)
            return [split.base, split.pathExtension]
        }

        XCTAssertEqual(parts("a.pdf"), ["a", "pdf"])
        XCTAssertEqual(parts("a.tar.gz"), ["a.tar", "gz"])
        XCTAssertEqual(parts("main.c++"), ["main", "c++"])
        XCTAssertEqual(parts("notes.txt~"), ["notes", "txt~"])
        XCTAssertEqual(parts("song.mp3"), ["song", "mp3"])
        // A space ends the claim.
        XCTAssertEqual(parts("v1.2 final"), ["v1.2 final", ""])
        // All digits: a time, a date, a version.
        XCTAssertEqual(parts("Screen Shot at 1.02.33"), ["Screen Shot at 1.02.33", ""])
        XCTAssertEqual(parts("archive.001"), ["archive.001", ""])
        // Nothing after the dot, no dot, a dot that leads, and too long to be a type.
        XCTAssertEqual(parts("name."), ["name.", ""])
        XCTAssertEqual(parts("name"), ["name", ""])
        XCTAssertEqual(parts(".profile"), [".profile", ""])
        XCTAssertEqual(parts("a." + String(repeating: "x", count: 16)), ["a", String(repeating: "x", count: 16)])
        XCTAssertEqual(parts("a." + String(repeating: "x", count: 17))[1], "")
        // A dot with a combining mark after it is still the dot (unicode scalars).
        XCTAssertEqual(parts("a.\u{0301}pdf"), ["a", "\u{0301}pdf"])
    }

    /// Revert-check: allowing only letters and digits in `splitExtension` makes this fail:
    /// `truncated` then cuts through the `.c++` it no longer reads as an extension.
    func testFilename_aVeryLongNameWithAnOddExtension_keepsTheExtension() {
        let name = Policy.filename(storedFilename: String(repeating: "a", count: 400) + ".c++", typeExtension: "txt")

        XCTAssertEqual(name.utf8.count, Policy.maximumFilenameUTF8Count)
        XCTAssertTrue(name.hasSuffix("a.c++"))
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
        // By the same rule as everything else: before an odd extension, after a version.
        XCTAssertEqual(Policy.availableFilename("main.c++") { $0 == "main.c++" }, "main 2.c++")
        XCTAssertEqual(Policy.availableFilename("v1.2") { $0 == "v1.2" }, "v1.2 2")
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
