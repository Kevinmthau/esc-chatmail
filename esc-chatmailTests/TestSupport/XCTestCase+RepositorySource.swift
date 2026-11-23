import XCTest

extension XCTestCase {
    /// The text of a file of this repository, by its path from the repository's root
    /// (`"esc-chatmail/Views/Chat/ChatView.swift"`), for a suite that pins something from
    /// source text because no test can run it.
    ///
    /// One copy, shared. Twenty-two suites had a reader of their own when this was added, and
    /// each walks up from its own `#filePath` by the depth of the directory that test file is
    /// in, so a test file that moves reads from the wrong place. This one walks up from this
    /// file, and says which root it tried where that is not the repository.
    func repositorySource(
        _ relativePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let root = repositoryRoot(file: file, line: line)
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The paths, from the repository's root, of every `.swift` file under `relativeDirectory`
    /// (`"esc-chatmail"`), sorted, for a pin that must hold in every file of a directory.
    func repositorySwiftFilePaths(
        under relativeDirectory: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String] {
        let root = repositoryRoot(file: file, line: line)
        let directory = root.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let rootPrefix = root.standardizedFileURL.path + "/"
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { url in
                let path = url.standardizedFileURL.path
                return path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
            }
            .sorted()
    }

    private func repositoryRoot(file: StaticString, line: UInt) -> URL {
        // This file is esc-chatmailTests/TestSupport/, so the repository's root is three
        // directories up. `#filePath` here is this file's path, not the caller's.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("esc-chatmail.xcodeproj").path),
            "Not the repository's root: \(root.path)",
            file: file,
            line: line
        )
        return root
    }
}
