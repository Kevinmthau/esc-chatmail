import UniformTypeIdentifiers
import XCTest
@testable import esc_chatmail

/// Which attachments the Mac's chat offers to open in another app (`AttachmentOpenPolicy`).
/// Plain values and the system's table of file types, so this runs in the iOS suite and in
/// `Mac.xctestplan`.
///
/// The refusals are asked by type as well as by name. A name is looked up in the system's
/// table, and an extension the table does not have is refused for that reason alone, which
/// would let a rule that had stopped refusing scripts pass a test that only asked by name.
final class AttachmentOpenPolicyTests: XCTestCase {
    private typealias Policy = AttachmentOpenPolicy

    // MARK: - What is opened

    func testIsOpenable_picturesSoundFilmAndPDFs_areOpened() {
        for name in ["Beach.jpg", "IMG_0042.HEIC", "chart.png", "loop.gif", "Report.pdf", "song.mp3", "clip.mov", "clip.mp4"] {
            XCTAssertTrue(Policy.isOpenable(filename: name), name)
        }
    }

    func testIsOpenable_plainTextAndOfficeDocuments_areOpened() {
        for name in ["notes.txt", "letter.rtf", "table.csv", "Plan.docx", "Budget.xlsx", "Deck.pptx"] {
            XCTAssertTrue(Policy.isOpenable(filename: name), name)
        }
    }

    /// The kinds named one by one, asked by their identifiers. One the system running the
    /// test does not declare is passed over; none is found refused.
    func testIsOpenable_theOtherNamedKinds_areOpenedWhereTheSystemKnowsThem() {
        let identifiers = [
            "com.microsoft.word.doc", "com.microsoft.excel.xls", "com.microsoft.powerpoint.ppt",
            "com.apple.iwork.pages.sffpages", "com.apple.iwork.numbers.sffnumbers",
            "com.apple.iwork.keynote.sffkey", "org.idpf.epub-container", "com.apple.ical.ics",
            "public.vcard", "net.daringfireball.markdown", "public.tab-separated-values-text"
        ]
        var asked = 0
        for identifier in identifiers {
            guard let type = UTType(identifier) else { continue }
            asked += 1
            XCTAssertTrue(Policy.isOpenable(type), identifier)
        }
        XCTAssertGreaterThan(asked, 0)
    }

    // MARK: - What is not

    /// Every script and source file conforms to plain text, which is why plain text is named
    /// as itself and is not one of the families.
    ///
    /// Revert-check: adding `.plainText` to `AttachmentOpenPolicy.openableFamilies` makes this
    /// fail: `run.command` would open in Terminal.
    func testIsOpenable_scriptsAndSourceCode_areNot_thoughTheyArePlainText() {
        XCTAssertTrue(UTType.shellScript.conforms(to: .plainText))
        for type in [UTType.shellScript, .pythonScript, .appleScript, .javaScript, .sourceCode, .swiftSource, .script] {
            XCTAssertFalse(Policy.isOpenable(type), type.identifier)
        }
        for name in ["run.command", "install.sh", "tool.py", "page.js"] {
            XCTAssertFalse(Policy.isOpenable(filename: name), name)
        }
    }

    /// Revert-check: emptying `AttachmentOpenPolicy.refusedWithinFamilies` makes this fail:
    /// an SVG is an image, and it opens in the browser with whatever script it carries.
    func testIsOpenable_anSVG_isNot_thoughItIsAnImage() {
        XCTAssertTrue(UTType.svg.conforms(to: .image))
        XCTAssertFalse(Policy.isOpenable(.svg))
        XCTAssertFalse(Policy.isOpenable(filename: "logo.svg"))
    }

    /// Revert-check: returning true from `AttachmentOpenPolicy.isOpenable(_:)` for any type
    /// that conforms to `.data` makes this fail.
    func testIsOpenable_programsInstallersArchivesAndWebPages_areNot() {
        let types: [UTType] = [
            .application, .applicationBundle, .executable, .unixExecutable, .exe,
            .diskImage, .zip, .archive, .html, .webArchive, .xml, .json, .propertyList,
            .internetLocation, .urlBookmarkData, .aliasFile, .symbolicLink, .folder, .data, .item
        ]
        for type in types {
            XCTAssertFalse(Policy.isOpenable(type), type.identifier)
        }
        for name in ["Setup.pkg", "App.dmg", "site.html", "link.webloc", "files.zip", "Tool.app", "a.jar", "p.mobileconfig"] {
            XCTAssertFalse(Policy.isOpenable(filename: name), name)
        }
    }

    /// A macro-enabled Office file is a type of its own and is not the one that is named.
    ///
    /// HONEST SCOPE: no change to the rule makes this fail today, because nothing the system
    /// declares conforms to the named Office types. It pins the names that must stay out if
    /// the named kinds are ever decided by conformance.
    func testIsOpenable_macroEnabledOfficeFiles_areNot() {
        for name in ["Plan.docm", "Budget.xlsm", "Deck.pptm"] {
            XCTAssertFalse(Policy.isOpenable(filename: name), name)
        }
    }

    /// What decides the app is the last extension, which is what is asked.
    ///
    /// HONEST SCOPE: which part of a name is its extension is `splitExtension`'s, with tests
    /// of its own. This pins the outcome for the names a sender would try.
    func testIsOpenable_isDecidedByTheLastExtension() {
        XCTAssertFalse(Policy.isOpenable(filename: "invoice.pdf.command"))
        XCTAssertFalse(Policy.isOpenable(filename: "photo.jpg.app"))
        XCTAssertTrue(Policy.isOpenable(filename: "archive.zip.pdf"))
    }

    /// Revert-check: deleting the `guard !type.isDynamic` and the `guard !pathExtension.isEmpty`
    /// from `AttachmentOpenPolicy` leaves this passing, because a made-up type conforms to
    /// nothing named. HONEST SCOPE: it pins the outcome, not those two lines.
    func testIsOpenable_aNameWithNoExtension_orOneTheSystemDoesNotKnow_isNot() {
        XCTAssertFalse(Policy.isOpenable(filename: "Makefile"))
        XCTAssertFalse(Policy.isOpenable(filename: "Screen Shot at 1.02.33"))
        XCTAssertFalse(Policy.isOpenable(filename: "data.zzqxv"))
        XCTAssertFalse(Policy.isOpenable(filename: ""))
    }

    // MARK: - The alert's text

    func testFailureMessage_saysWhatHappened_andForAKindThatIsNotOpened_whatToDo() {
        XCTAssertEqual(
            Policy.failureMessage(for: .sourceMissing(filename: "Report.pdf")),
            "Report.pdf is no longer on this Mac."
        )
        XCTAssertEqual(
            Policy.failureMessage(for: .kindNotOpened(filename: "Setup.pkg")),
            "MushMail does not open files like Setup.pkg. Save it, and open it from the Finder."
        )
        XCTAssertEqual(
            Policy.failureMessage(for: .copyFailed(filename: "Report.pdf", reason: "The disk is full.")),
            "Report.pdf could not be opened. The disk is full."
        )
        XCTAssertEqual(
            Policy.failureMessage(for: .notOpened(filename: "Report.pdf")),
            "Report.pdf could not be opened. No app on this Mac opened it."
        )
    }
}
