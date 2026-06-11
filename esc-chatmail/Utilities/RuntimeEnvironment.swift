import Foundation

/// Single source of truth for "how is this process running" checks.
///
/// Centralized so the unit-test detection used by both the app entry point and
/// `CoreDataStack` can never drift between sites.
enum RuntimeEnvironment {
    /// True when this process is hosting unit tests (XCTest is loaded
    /// in-process). UI tests run the app in a separate process without XCTest,
    /// so this stays false for them.
    static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}
