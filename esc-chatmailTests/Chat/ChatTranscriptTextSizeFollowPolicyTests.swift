import XCTest
@testable import esc_chatmail

/// When a change of text size arms a fresh bottom follow (architecture review 2026-11,
/// gap-accessibility-architecture#4). In the default plan and in `Mac.xctestplan`.
///
/// The coordinator's use of the policy, what the follow then scrolls, and that only the change of
/// size arms one are pinned in `ChatMessagesCoordinatorTests` (its text-size tests).
final class ChatTranscriptTextSizeFollowPolicyTests: XCTestCase {
    /// Revert-check: making `ChatTranscriptTextSizeFollowPolicy.armsFollow` answer `false` fails
    /// this.
    func testArmsFollow_forAReaderAtRestAtTheBottomOfARevealedChatOnScreen() {
        XCTAssertTrue(arms())
    }

    /// Each term refuses on its own.
    ///
    /// Revert-check: dropping any one term from `ChatTranscriptTextSizeFollowPolicy.armsFollow`
    /// fails the assertion that names it.
    func testArmsFollow_isRefusedByEachTermOnItsOwn() {
        XCTAssertFalse(arms(wasBottomAnchorVisible: false), "wasBottomAnchorVisible")
        XCTAssertFalse(arms(isTranscriptRevealed: false), "isTranscriptRevealed")
        XCTAssertFalse(arms(isChatVisible: false), "isChatVisible")
        XCTAssertFalse(arms(isUserScrollTakeoverActive: true), "isUserScrollTakeoverActive")
        XCTAssertFalse(arms(isUserScrollInteractionActive: true), "isUserScrollInteractionActive")
        XCTAssertFalse(arms(isScrollPhaseUserDriven: true), "isScrollPhaseUserDriven")
    }

    /// The chat reports its text size with every geometry report, and the coordinator decides
    /// from the report, not from an `onChange(of: dynamicTypeSize)`: the report carrying a new
    /// size's growth runs before that `onChange` (`ChatTranscriptTextSizeFollowPolicy`).
    ///
    /// Revert-check: passing `textSize: .large` in place of `geometry.dynamicTypeSize` in
    /// `ChatMessagesView.handleBottomAnchorGeometryUpdate` fails this.
    ///
    /// HONEST SCOPE: this reads source text. Nothing here changes a text size; the order of the
    /// report and the `onChange` was measured once, in a throwaway hosted probe on the iOS 27.0
    /// simulator, and is not re-run.
    func testChatMessagesView_carriesTheTextSizeInEveryGeometryReport() throws {
        let source = try repositorySource("esc-chatmail/Views/Chat/ChatMessagesView.swift")

        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
        XCTAssertTrue(source.contains("                    dynamicTypeSize: dynamicTypeSize\n"))
        XCTAssertTrue(source.contains("    let dynamicTypeSize: DynamicTypeSize\n"))
        XCTAssertTrue(source.contains("            textSize: geometry.dynamicTypeSize\n"))
        XCTAssertFalse(source.contains(".onChange(of: dynamicTypeSize)"))
    }

    private func arms(
        wasBottomAnchorVisible: Bool = true,
        isTranscriptRevealed: Bool = true,
        isChatVisible: Bool = true,
        isUserScrollTakeoverActive: Bool = false,
        isUserScrollInteractionActive: Bool = false,
        isScrollPhaseUserDriven: Bool = false
    ) -> Bool {
        ChatTranscriptTextSizeFollowPolicy.armsFollow(
            wasBottomAnchorVisible: wasBottomAnchorVisible,
            isTranscriptRevealed: isTranscriptRevealed,
            isChatVisible: isChatVisible,
            isUserScrollTakeoverActive: isUserScrollTakeoverActive,
            isUserScrollInteractionActive: isUserScrollInteractionActive,
            isScrollPhaseUserDriven: isScrollPhaseUserDriven
        )
    }
}
