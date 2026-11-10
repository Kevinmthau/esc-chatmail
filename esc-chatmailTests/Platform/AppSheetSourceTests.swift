import XCTest
@testable import esc_chatmail

/// Every sheet the Mac can present must go through `View.appSheet`, which takes its Mac chrome
/// as a required argument. A sheet presented with SwiftUI's own `sheet` gets no Mac size and
/// comes up there as an empty strip 80 points tall that still blocks the window and Quit
/// (`MacSheetSize`). A `sheet` inside an `#if os(iOS)` branch is left alone: the Mac never
/// compiles it (the iOS document picker, whose Mac counterpart is a file importer).
///
/// HONEST SCOPE: this reads source text, as `LogRedactionTests` and `SandboxTripwireTests` do.
/// It does not see a sheet presented some other way (AppKit, a `fullScreenCover`, which the Mac
/// does not have), and it cannot tell whether the chrome a call site names is the right one.
final class AppSheetSourceTests: XCTestCase {
    /// Revert-check: replacing `.appSheet(isPresented: $showingComposer, mac: .sized(.compose),`
    /// in `ConversationListView` with `.sheet(isPresented: $showingComposer,` makes this fail.
    func testAppSources_sheetModifier_isCalledOnlyByThePresenter() throws {
        let offenders = try appSources()
            .filter { $0.fileName != Self.presenterFileName }
            .flatMap { source in
                Self.sheetCallsCompiledForMac(in: source.lines).map { "\(source.fileName): \($0)" }
            }

        XCTAssertEqual(
            offenders,
            [],
            "Present sheets with appSheet(isPresented:mac:...) or appSheet(item:mac:...), which give them their Mac size"
        )
    }

    /// The scan above proves nothing if the presenter itself stopped calling `sheet`, or moved.
    ///
    /// Revert-check: renaming `View+AppSheet.swift` makes this fail.
    func testAppSources_presenter_callsSheetForBothForms() throws {
        let presenter = try XCTUnwrap(appSources().first { $0.fileName == Self.presenterFileName })

        XCTAssertEqual(
            Self.sheetCallsCompiledForMac(in: presenter.lines).count,
            2,
            "one for isPresented:, one for item:"
        )
    }

    /// Only an `#if os(iOS)` branch is exempt: its `#else` is what the Mac compiles, and any
    /// other condition might be.
    ///
    /// Revert-check: making `sheetCallsCompiledForMac` skip every `#if` branch makes the second
    /// and third assertions fail; making it skip none makes the first fail.
    func testSheetCallsCompiledForMac_exemptsOnlyTheIOSBranch() {
        XCTAssertEqual(
            Self.sheetCallsCompiledForMac(in: ["#if os(iOS)", "sheet(isPresented: a) {", "#endif"]),
            []
        )
        XCTAssertEqual(
            Self.sheetCallsCompiledForMac(in: ["#if os(iOS)", "self", "#else", "sheet(isPresented: b) {", "#endif"]),
            ["sheet(isPresented: b) {"]
        )
        XCTAssertEqual(
            Self.sheetCallsCompiledForMac(in: ["#if DEBUG", ".sheet(item: c) { _ in", "#endif", ".sheet(item: d) { _ in"]),
            [".sheet(item: c) { _ in", ".sheet(item: d) { _ in"]
        )
        XCTAssertEqual(
            Self.sheetCallsCompiledForMac(
                in: ["#if os(iOS)", "#if DEBUG", ".sheet(item: e) { _ in", "#endif", "#endif", ".sheet(item: f) { _ in"]
            ),
            [".sheet(item: f) { _ in"]
        )
    }

    func testCallsSheetModifier_matchesCallsAndIgnoresCommentsAndOtherNames() {
        XCTAssertTrue(Self.callsSheetModifier(".sheet(isPresented: $showingComposer) {"))
        XCTAssertTrue(Self.callsSheetModifier("content.sheet(item: $item) { _ in"))
        XCTAssertTrue(Self.callsSheetModifier("sheet(isPresented: isPresented, onDismiss: onDismiss) {"))
        XCTAssertFalse(Self.callsSheetModifier("// a raw .sheet( would bring back the strip"))
        XCTAssertFalse(Self.callsSheetModifier("/// SwiftUI's `sheet(isPresented:onDismiss:content:)`"))
        XCTAssertFalse(Self.callsSheetModifier(".appSheet(isPresented: $showingComposer, mac: .sized(.compose)) {"))
        XCTAssertFalse(Self.callsSheetModifier("func appSheet<Content: View>("))
        XCTAssertFalse(Self.callsSheetModifier("destinationSheet(destination)"))
        XCTAssertFalse(Self.callsSheetModifier("ContactsSheet(kind: .newContact(contact))"))
    }

    private static let presenterFileName = "View+AppSheet.swift"

    /// The trimmed lines among `lines` that call `sheet` in code the Mac compiles: all of it
    /// except what sits inside an `#if os(iOS)` branch.
    private static func sheetCallsCompiledForMac(in lines: [String]) -> [String] {
        // One entry per open `#if`: whether the branch being read is iOS-only.
        var branches: [Bool] = []
        var calls: [String] = []
        for line in lines {
            if line.hasPrefix("#if ") {
                branches.append(line == "#if os(iOS)")
            } else if line.hasPrefix("#else") {
                // Covers `#elseif` too.
                if !branches.isEmpty {
                    branches[branches.count - 1] = false
                }
            } else if line.hasPrefix("#endif") {
                _ = branches.popLast()
            } else if !branches.contains(true), callsSheetModifier(line) {
                calls.append(line)
            }
        }
        return calls
    }

    /// Whether a trimmed source line calls a function or modifier named exactly `sheet`.
    private static func callsSheetModifier(_ line: String) -> Bool {
        guard !line.hasPrefix("//") else { return false }
        var searchRange = line.startIndex..<line.endIndex
        while let match = line.range(of: "sheet(", range: searchRange) {
            let isWholeName: Bool
            if match.lowerBound == line.startIndex {
                isWholeName = true
            } else {
                let previous = line[line.index(before: match.lowerBound)]
                isWholeName = !(previous.isLetter || previous.isNumber || previous == "_")
            }
            if isWholeName { return true }
            searchRange = match.upperBound..<line.endIndex
        }
        return false
    }

    /// The app target's Swift sources, each as whitespace-trimmed lines.
    private func appSources() throws -> [(fileName: String, lines: [String])] {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appRoot = repoRoot.appendingPathComponent("esc-chatmail", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: appRoot.appendingPathComponent("Platform/\(Self.presenterFileName)").path
            ),
            "Scan root must be the app target: \(appRoot.path)"
        )

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var sources: [(fileName: String, lines: [String])] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = contents
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            sources.append((fileName: fileURL.lastPathComponent, lines: lines))
        }
        XCTAssertGreaterThan(sources.count, 100, "Expected to scan the app's Swift sources at \(appRoot.path)")
        return sources
    }
}
