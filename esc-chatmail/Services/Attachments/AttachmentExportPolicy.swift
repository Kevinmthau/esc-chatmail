import Foundation

/// What a chat offers for an attachment that is saved out of the app (the Mac's Save
/// Attachment…; `MacAttachmentExportMenu`), and the name the saved file is given.
///
/// An attachment's name is the sender's, taken from the email as it came, and the file on disk
/// is named for its storage identity (`AttachmentPaths`), so the name a save offers is made
/// here.
enum AttachmentExportPolicy {
    /// One entry of an attachment's menu.
    enum MenuItem: Equatable {
        case quickLook
        case save
        /// Saves every attachment the message shows that has a file; `count` of them.
        case saveAll(count: Int)
    }

    /// The menu of an attachment the user right-clicked, top to bottom, each with whether it
    /// can be chosen.
    ///
    /// The menu is the same for every state of the attachment, with the entries that need its
    /// file disabled until it has one: a menu that came and went with a download would be a
    /// different menu from one click to the next.
    ///
    /// - Parameters:
    ///   - isReady: The clicked attachment has its file (downloaded, or sent from here).
    ///   - readyCount: How many of the attachments the message shows have theirs, the clicked
    ///     one included.
    ///   - shownCount: How many attachments the message shows.
    static func menu(isReady: Bool, readyCount: Int, shownCount: Int) -> [(item: MenuItem, isEnabled: Bool)] {
        var items: [(item: MenuItem, isEnabled: Bool)] = [
            (.quickLook, isReady),
            (.save, isReady)
        ]
        // One attachment has nothing to add to "Save Attachment…".
        if shownCount > 1 {
            items.append((.saveAll(count: readyCount), readyCount > 0))
        }
        return items
    }

    static func title(for item: MenuItem) -> String {
        switch item {
        case .quickLook:
            return "Quick Look"
        case .save:
            return "Save Attachment…"
        case .saveAll:
            return "Save All Attachments…"
        }
    }

    /// The line above the folder list when Save All asks where to save.
    static func folderPrompt(count: Int) -> String {
        count == 1 ? "Choose a folder for 1 attachment." : "Choose a folder for \(count) attachments."
    }

    /// The title of the alert that lists the attachments a save could not write.
    static func failureTitle(failureCount: Int) -> String {
        failureCount == 1 ? "Attachment Not Saved" : "Some Attachments Weren’t Saved"
    }

    // MARK: - The saved file's name

    /// The name used where the sender's leaves nothing usable.
    static let fallbackBaseName = "Attachment"

    /// The longest name offered, in UTF-8 bytes. A file name can be 255; this leaves room for
    /// the " 2" that keeps two saved files apart (`availableFilename`).
    static let maximumFilenameUTF8Count = 240

    /// The name a saved attachment is offered under: the sender's name with everything removed
    /// that is not part of a plain file name.
    ///
    /// The name comes from the email and is untrusted. It is shown in the save panel and, for
    /// Save All, used as it is, so none of these may survive:
    /// - **A path.** Only the last component is kept, with `/` and `\` both read as
    ///   separators, so a name cannot place the file somewhere else. A `:` becomes `-`: the
    ///   Finder shows it as a slash.
    /// - **Control and direction characters.** A right-to-left override makes
    ///   `invoice\u{202E}fdp.exe` read as `invoiceexe.pdf`.
    /// - **A leading dot**, which would hide the saved file.
    ///
    /// - Parameters:
    ///   - storedFilename: `Attachment.filename`.
    ///   - sourceExtension: The extension of the file on disk. Given to a name with nothing
    ///     after a dot, where the download took it from the attachment's type, so the saved
    ///     file opens.
    static func filename(storedFilename: String, sourceExtension: String) -> String {
        // Unicode scalars throughout, never `Character`s. A "/" followed by a combining scalar
        // (a zero-width joiner, an accent) is one `Character` that is not "/", so a split on
        // `Character`s kept `Library/\u{200D}x.plist` whole, and Save All wrote it into a
        // `Library` folder of the folder the user chose. The same goes for a leading dot.
        let lastComponent = Array(storedFilename.unicodeScalars)
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last ?? []
        let kept = lastComponent
            .filter { !isRemoved($0) }
            .map { $0 == ":" ? Unicode.Scalar("-") : $0 }
        var name = string(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.unicodeScalars.first == "." {
            name = string(name.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if name.isEmpty {
            name = fallbackBaseName
        }
        let cleanExtension = sourceExtension.filter { $0.isLetter || $0.isNumber }
        if !hasSuffixAfterDot(name), !cleanExtension.isEmpty, cleanExtension != unknownTypeExtension {
            // A name that ended in a dot would otherwise get two.
            while name.unicodeScalars.last == "." {
                name = string(name.unicodeScalars.dropLast())
            }
            name += ".\(cleanExtension)"
        }
        return truncated(name)
    }

    /// The extension the download gives a file whose type it does not know
    /// (`AttachmentPaths.fileExtension`). It says nothing about the file, so it is not added
    /// to a name: `Makefile` stays `Makefile`.
    static let unknownTypeExtension = AttachmentPaths.fileExtension(for: "application/octet-stream")

    /// Whether a name already ends in something after a dot, so the stored file's extension is
    /// not added to it. Looser than `splitExtension`: `main.c++` and `notes.txt~` end in
    /// one, and the download named the stored file after it. A space ends the claim:
    /// `report v1.2 final` has none.
    static func hasSuffixAfterDot(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let dot = scalars.lastIndex(of: "."), dot > 0 else { return false }
        let suffix = scalars[(dot + 1)...]
        return !suffix.isEmpty && !suffix.contains(where: { $0.properties.isWhitespace })
    }

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// `name`, or `name` with a number before its extension, whichever is first not taken:
    /// `Photo.jpg`, `Photo 2.jpg`, `Photo 3.jpg`. Save All never replaces a file in the folder
    /// the user chose, which nothing asked them about.
    static func availableFilename(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let parts = splitExtension(of: name)
        var number = 2
        while true {
            let candidate = parts.pathExtension.isEmpty
                ? "\(parts.base) \(number)"
                : "\(parts.base) \(number).\(parts.pathExtension)"
            if !isTaken(candidate) {
                return candidate
            }
            number += 1
        }
    }

    /// The longest run after a name's last dot that is still read as its type.
    private static let maximumExtensionLength = 16

    /// A name's extension and what stands before it. Only letters and digits after the last
    /// dot are an extension: `report v1.2 final` has none, and is given the file's own.
    static func splitExtension(of name: String) -> (base: String, pathExtension: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        let candidate = name[name.index(after: dot)...]
        guard !candidate.isEmpty,
              candidate.count <= maximumExtensionLength,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return (name, "")
        }
        return (String(name[..<dot]), String(candidate))
    }

    /// The direction marks, embeddings, overrides and isolates.
    private static let directionScalars: Set<UInt32> = [
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ]

    /// Control characters, line breaks, and the characters that change the direction text is
    /// drawn in. Other invisible characters stay: a zero-width joiner is part of an emoji.
    private static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        if directionScalars.contains(scalar.value) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// Shortens the base name, never the extension, until the whole name fits.
    private static func truncated(_ name: String) -> String {
        guard name.utf8.count > maximumFilenameUTF8Count else { return name }
        let parts = splitExtension(of: name)
        let suffix = parts.pathExtension.isEmpty ? "" : ".\(parts.pathExtension)"
        let base = prefix(of: parts.base, fittingUTF8Count: maximumFilenameUTF8Count - suffix.utf8.count)
        return base + suffix
    }

    /// Cut between scalars, not `Character`s: one `Character` can be longer than the limit
    /// (a letter with hundreds of combining marks), and a cut between `Character`s would then
    /// keep nothing.
    private static func prefix(of string: String, fittingUTF8Count limit: Int) -> String {
        var kept = String.UnicodeScalarView()
        var count = 0
        for scalar in string.unicodeScalars {
            let width = UTF8.width(scalar)
            guard count + width <= limit else { break }
            kept.append(scalar)
            count += width
        }
        return String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
