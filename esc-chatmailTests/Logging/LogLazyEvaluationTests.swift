import XCTest
@testable import esc_chatmail

final class LogLazyEvaluationTests: XCTestCase {
    /// `Log.debug` takes its message as an autoclosure, but the private
    /// `Log.log(level:message:...)` used to take a `String`, so every entry
    /// point evaluated the message before the level guard ran. Debug's
    /// default minimum level is `.info`, so this exercises the real
    /// configuration the test run uses.
    ///
    /// Revert-check: the `@autoclosure () -> String` type of the `message`
    /// parameter of `Log.log(level:message:category:error:file:function:line:)`
    /// and its `message()` evaluation after the level and category guards;
    /// restoring the eager `String` parameter evaluates the counter closure
    /// and fails this test.
    func testDebug_belowMinimumLevel_doesNotEvaluateMessage() throws {
        try XCTSkipUnless(
            LoggerConfiguration.current.minimumLevel > .debug,
            "Lazy evaluation is only observable when debug logging is disabled"
        )

        var evaluations = 0
        func expensiveMessage() -> String {
            evaluations += 1
            return "expensive debug message"
        }

        Log.debug(expensiveMessage(), category: .general)
        Log.debug(expensiveMessage(), category: .sync)
        LogCategory.sync.logger.debug(expensiveMessage())

        XCTAssertEqual(evaluations, 0)
    }

    /// The level guard, not the laziness, decides what is logged: a message at
    /// or above the minimum level is still evaluated exactly once.
    func testError_atOrAboveMinimumLevel_evaluatesMessageOnce() {
        var evaluations = 0
        func message() -> String {
            evaluations += 1
            return "error message"
        }

        Log.error(message(), category: .general)

        XCTAssertEqual(evaluations, 1)
    }
}
