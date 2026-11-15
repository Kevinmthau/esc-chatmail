import XCTest
@testable import esc_chatmail

/// Two things about the chat cards' text that only source shows: the bubble hands its style's
/// card metrics down, and no view asks for the rounded font design.
///
/// A card reads `EmailPreviewCardMetrics` from the environment, whose default is the
/// iPhone's. If `MessageBubble` stopped setting it, nothing would fail to compile and no
/// value test would notice: the Mac's cards would be back at the iPhone's sizes, a 17-point
/// title beside 13-point bubble text.
///
/// HONEST SCOPE: this reads source text, as `ChatBubbleStyleSourceTests` does, and matches
/// spelling. It does not see what a card draws, and a font built some way these patterns do
/// not spell (a `UIFontDescriptor` with a rounded design) would pass.
final class EmailPreviewCardSourceTests: XCTestCase {
    /// Revert-check: deleting `.environment(\.emailPreviewCardMetrics, style.previewCardMetrics)`
    /// from `MessageBubble.body` makes this fail.
    func testBubble_handsItsContentTheStylesCardMetrics() throws {
        let bubble = try String(
            contentsOf: repoRoot().appendingPathComponent("esc-chatmail/Views/Chat/MessageBubble.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(bubble.contains(
            "                )\n"
                + "                // The cards under this content (preview cards, the forwarded card, shared\n"
                + "                // files) take their text sizes from the style: without this they draw at the\n"
                + "                // iPhone's sizes in the Mac's chat column.\n"
                + "                .environment(\\.emailPreviewCardMetrics, style.previewCardMetrics)\n"
        ))
    }

    /// The cards were the app's only rounded text, and they are SF Pro now
    /// (`EmailPreviewCardMetrics.font(size:weight:)`).
    ///
    /// Revert-check: `.font(.system(size: 17, weight: .semibold, design: .rounded))` on any
    /// text in the app target makes this fail.
    func testAppSources_askForNoRoundedFontDesign() throws {
        let appRoot = try repoRoot().appendingPathComponent("esc-chatmail", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))

        var scanned = 0
        var offenders: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            scanned += 1
            let lines = try String(contentsOf: fileURL, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") else { continue }
                if code.contains("design: .rounded") || code.contains("fontDesign(.rounded)") {
                    offenders.append("\(fileURL.lastPathComponent):\(index + 1): \(code)")
                }
            }
        }

        XCTAssertGreaterThan(scanned, 100, "Expected to scan the app's Swift sources at \(appRoot.path)")
        XCTAssertEqual(offenders, [], "The app's text is SF Pro: use the default font design")
    }

    private func repoRoot() throws -> URL {
        // This file is esc-chatmailTests/Platform/, so the repo root is three directories up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("esc-chatmail.xcodeproj").path),
            "Scan root must be the repository: \(root.path)"
        )
        return root
    }
}
