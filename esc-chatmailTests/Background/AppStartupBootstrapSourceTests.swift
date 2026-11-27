import XCTest
@testable import esc_chatmail

/// The process services (the tombstone sweep, `CacheCoordinator.shared.start()`) start
/// from `AppStartupBootstrap`'s process-services operation and from nowhere else, so a
/// background task's cold launch, which never runs `initializeApp()`, has them too
/// (architecture review 2026-11, di-modularity#4, gap-change-propagation-pipeline#5).
/// Pinned from source: the production operation touches the shared coordinator and the
/// disk, which no hosted test may run.
final class AppStartupBootstrapSourceTests: XCTestCase {
    // Revert-check: fails if either call comes back to `initializeApp()`, leaves
    // `startProductionProcessServices`, loses its unit-test guard, or the sweep stops
    // running before the coordinator starts.
    func testProcessServices_startFromTheBootstrap_notFromInitializeApp() throws {
        let app = try source("esc-chatmail/App/esc_chatmailApp.swift")
        XCTAssertFalse(app.contains("CacheCoordinator.shared.start()"))
        XCTAssertFalse(app.contains("RetiredAccountDirectory.sweepLeftovers()"))

        let bootstrap = try source("esc-chatmail/App/AppStartupBootstrap.swift")
        let function = try XCTUnwrap(bootstrap.range(of: "private func startProductionProcessServices()"))
        let unitTestGuard = try XCTUnwrap(bootstrap.range(of: "guard !RuntimeEnvironment.isRunningUnitTests"))
        let sweep = try XCTUnwrap(bootstrap.range(of: "RetiredAccountDirectory.sweepLeftovers()"))
        let start = try XCTUnwrap(bootstrap.range(of: "CacheCoordinator.shared.start()"))
        XCTAssertLessThan(function.lowerBound, unitTestGuard.lowerBound)
        XCTAssertLessThan(unitTestGuard.lowerBound, sweep.lowerBound)
        XCTAssertLessThan(sweep.lowerBound, start.lowerBound)
        XCTAssertEqual(bootstrap.components(separatedBy: "CacheCoordinator.shared.start()").count - 1, 1)
        XCTAssertTrue(
            bootstrap.contains("await startProcessServicesOperation()"),
            "The single flight's task runs the services once persistence succeeded"
        )
    }

    private func source(_ path: String) throws -> String {
        try repositorySource(path)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
