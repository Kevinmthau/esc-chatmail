import XCTest
@testable import esc_chatmail

final class FullEmailPlaceholderSurfaceTests: XCTestCase {
    func testUnrecoverableFailurePlaceholderOverlayShowsMessageWithoutProgress() throws {
        let overlayState = try XCTUnwrap(FullEmailPlaceholderOverlayState.failure(allowsRetry: false))

        XCTAssertEqual(overlayState, .message("Original email unavailable"))
        XCTAssertFalse(overlayState.showsProgress)
    }

    func testResolvingPlaceholderOverlaysShowProgress() {
        let loadingState = FullEmailPlaceholderOverlayState.resolving(isRecovering: false)
        let recoveringState = FullEmailPlaceholderOverlayState.resolving(isRecovering: true)

        XCTAssertEqual(loadingState, .loading("Loading full email…"))
        XCTAssertTrue(loadingState.showsProgress)
        XCTAssertEqual(recoveringState, .loading("Recovering original email…"))
        XCTAssertTrue(recoveringState.showsProgress)
    }
}
