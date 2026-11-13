import Foundation
import UniformTypeIdentifiers

/// Which attachments the Mac's chat offers to open in another app (Open, in an attachment's
/// menu; `MacAttachmentExportMenu`).
///
/// Opening a file hands it to whatever app the system has for its kind, and the file is the
/// sender's. So the kinds are named here, one by one, and everything else is left to Save
/// Attachment…: an app, a script, an installer, a disk image, a web page, a link file, an
/// archive, a kind the system does not know. A file the user saves and opens from the Finder
/// is theirs to judge, with the system's own checks on it.
///
/// The kind is read from the extension of the name the copy is opened under
/// (`AttachmentExportItem.filename`), because that is what the system picks the app by. The
/// type the email claims is not asked: a `report.pdf` sent as `text/plain` opens as a PDF,
/// and a `run.command` sent as `image/png` is a script.
enum AttachmentOpenPolicy {
    /// Kinds opened with everything that conforms to them.
    private static let openableFamilies: [UTType] = [
        .image, .audio, .movie, .video, .pdf
    ]

    /// Kinds of image, sound and film that are not opened all the same.
    ///
    /// - An SVG is a web page in all but name: it opens in the browser and can carry script.
    /// - A picture, a sound or a film that is text is not one: it is a script or a list of
    ///   links. The system files Windows Media's redirectors under sound and film (`.wax` is
    ///   `public.audio`, `.wvx` is `public.movie`), and each is an XML file naming the
    ///   addresses a player is to fetch: a link file, which is never opened. Both are refused
    ///   twice over, as text and as redirectors (their parent type is named below); either
    ///   refusal alone holds them, and each also holds what the other does not name. SVG is
    ///   text too, and stays named for itself.
    /// - RealAudio is refused whole: a `.ram` file is a line of text with an address in it,
    ///   and the system gives it the type of the sound itself, so the two cannot be told
    ///   apart. A playlist conforms to none of the families today; it is named so that stays
    ///   true of whatever is declared under it.
    private static let refusedWithinFamilies: [UTType] = [.svg, .text, .playlist]
        + refusedIdentifiersWithinFamilies.compactMap { UTType($0) }

    /// The refused kinds the system has no constant for. One a system does not declare is
    /// passed over: no file there has that type, and its extension gets a made-up type that
    /// is refused for that.
    static let refusedIdentifiersWithinFamilies = [
        "com.microsoft.advanced-stream-redirector",
        "com.real.realaudio"
    ]

    /// Kinds opened only as themselves, never by conformance: a macro-enabled Word file is
    /// another type, and stays one that is not opened.
    private static let openableIdentifiers: Set<String> = [
        // Text that is only text. Plain text is here and not among the families because
        // every script and source file conforms to it.
        "public.plain-text",
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.utf16-external-plain-text",
        "public.rtf",
        "public.comma-separated-values-text",
        "public.tab-separated-values-text",
        "net.daringfireball.markdown",
        // Office documents that are not the macro-enabled types. The older three (`.doc`,
        // `.xls`, `.ppt`) have no macro-free form and can carry one; Office asks before it runs.
        "org.openxmlformats.wordprocessingml.document",
        "org.openxmlformats.spreadsheetml.sheet",
        "org.openxmlformats.presentationml.presentation",
        "com.microsoft.word.doc",
        "com.microsoft.excel.xls",
        "com.microsoft.powerpoint.ppt",
        // Pages, Numbers and Keynote, as single files.
        "com.apple.iwork.pages.sffpages",
        "com.apple.iwork.numbers.sffnumbers",
        "com.apple.iwork.keynote.sffkey",
        // What mail brings most besides: a book, an invitation, a contact.
        "org.idpf.epub-container",
        "com.apple.ical.ics",
        "public.vcard"
    ]

    /// Whether an attachment that would be opened under `filename` is of a kind that is
    /// opened. False for a name with no extension (`AttachmentExportPolicy.splitExtension`),
    /// which the system would open by guessing at the contents.
    static func isOpenable(filename: String) -> Bool {
        let pathExtension = AttachmentExportPolicy.splitExtension(of: filename).pathExtension
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension) else {
            return false
        }
        return isOpenable(type)
    }

    static func isOpenable(_ type: UTType) -> Bool {
        // An extension the system does not know gets a type made up for it, which conforms
        // to nothing here; said outright all the same.
        guard !type.isDynamic else { return false }
        if openableIdentifiers.contains(type.identifier) {
            return true
        }
        guard !refusedWithinFamilies.contains(where: { type.conforms(to: $0) }) else {
            return false
        }
        return openableFamilies.contains(where: { type.conforms(to: $0) })
    }

    // MARK: - When an attachment is not opened

    /// Why an attachment the user asked to open was not.
    enum Failure: Error, Equatable {
        /// The attachment has no file: gone since the menu was opened, by a sign-out or by
        /// storage cleanup.
        case sourceMissing(filename: String)
        /// Not a kind that is opened. The menu does not offer Open for one, so this is the
        /// opener refusing by itself whatever asked it.
        case kindNotOpened(filename: String)
        /// The copy to open could not be made; `reason` is the system's.
        case copyFailed(filename: String, reason: String)
        /// The system opened nothing: no app for the kind, or the app refused the file.
        case notOpened(filename: String)
    }

    /// The title of the alert that says an attachment was not opened.
    static let failureTitle = "Attachment Not Opened"

    static func failureMessage(for failure: Failure) -> String {
        switch failure {
        case .sourceMissing(let filename):
            return "\(filename) is no longer on this Mac."
        case .kindNotOpened(let filename):
            return "MushMail does not open files like \(filename). Save it, and open it from the Finder."
        case .copyFailed(let filename, let reason):
            return "\(filename) could not be opened. \(reason)"
        case .notOpened(let filename):
            return "\(filename) could not be opened. No app on this Mac opened it."
        }
    }
}
