import Foundation

/// What a chat offers for an attachment that is saved out of the app (the Mac's Save
/// Attachment…; `AttachmentExportMenuModifier`), and the name the saved file is given.
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
    ///   - sourceExtension: The extension of the file on disk, which the download took from
    ///     the attachment's type. Given to a name that has none, so the saved file opens.
    static func filename(storedFilename: String, sourceExtension: String) -> String {
        let lastComponent = storedFilename
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? ""
        let scalars = lastComponent.unicodeScalars.filter { !isRemoved($0) }
        var name = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let cleanExtension = sourceExtension.filter { $0.isLetter || $0.isNumber }
        if name.isEmpty {
            name = fallbackBaseName
        }
        if splitExtension(of: name).pathExtension.isEmpty, !cleanExtension.isEmpty {
            // A name that ended in a dot would otherwise get two.
            while name.hasSuffix(".") {
                name.removeLast()
            }
            name += ".\(cleanExtension)"
        }
        return truncated(name)
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

    private static func prefix(of string: String, fittingUTF8Count limit: Int) -> String {
        var result = ""
        var count = 0
        for character in string {
            let width = String(character).utf8.count
            guard count + width <= limit else { break }
            result.append(character)
            count += width
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
