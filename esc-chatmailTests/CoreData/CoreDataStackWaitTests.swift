import XCTest
@testable import esc_chatmail

final class CoreDataStackWaitTests: XCTestCase {

    func testWaitForStoreToLoad_failsImmediatelyWhenLoadErrorIsStored() async {
        let stack = CoreDataStack()
        let underlying = NSError(
            domain: "CoreDataStackWaitTests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "stored load failure"]
        )
        stack.debugSetStoreLoadErrorForTesting(underlying)

        let start = Date()

        do {
            try await stack.waitForStoreToLoad(timeout: 1.0)
            XCTFail("Expected waitForStoreToLoad to throw")
        } catch CoreDataError.storeLoadFailed(let error) {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, underlying.domain)
            XCTAssertEqual(nsError.code, underlying.code)
        } catch {
            XCTFail("Expected storeLoadFailed, got \(error)")
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            0.5,
            "Stored load errors should fail waiters immediately instead of waiting for timeout"
        )
    }
}
