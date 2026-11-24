import CoreData
import XCTest
@testable import esc_chatmail

/// The daily analyze and cleanup tasks run only against a store that loaded, and never
/// load it themselves: a cold background launch reaches their handlers without
/// `initializeApp`, so a handler that went straight to the stack made the store's first
/// load (and any migration or recovery-ladder step) ahead of the fresh-install cleanup,
/// and carried on against a coordinator with no store when that load was kept as failed.
///
/// Every test injects everything `DatabaseMaintenanceService` reaches (`makeService`): the
/// stack, the readiness, a run coordinator of its own, an HTML boundary over a temporary
/// directory and a recording attachment sweep. The defaults are the host's shared run
/// boundary and its real `Messages`, `Attachments` and `Previews`. Keep this suite out of
/// `Mac.xctestplan` all the same.
@MainActor
final class DatabaseMaintenanceStoreGateTests: XCTestCase {
    private var directoriesToRemove: [URL] = []

    override func tearDown() {
        for directory in directoriesToRemove {
            try? FileManager.default.removeItem(at: directory)
        }
        directoriesToRemove = []
        super.tearDown()
    }

    // Revert-check: the `persistenceReadiness()` guard in either handler of
    // `DatabaseMaintenanceService.registerBackgroundTasks()`. Without it the readiness is
    // never asked (the stack's own flag still refuses the run, which is the next test).
    func testHandlers_persistenceNotReady_returnFalseWithoutTouchingTheStore() async throws {
        let (container, storeURL) = TestCoreDataStack.makeStorelessContainer()
        directoriesToRemove.append(storeURL.deletingLastPathComponent())
        let stack = CoreDataStack(unloadedPersistentContainerForTesting: container)
        let readiness = ReadinessProbe(answer: false)
        let registry = CapturingTaskRegistry()
        let sweep = SweepRecorder()
        let service = makeService(
            registry: registry,
            stack: stack,
            readiness: { await readiness.ask() },
            sweep: sweep
        )

        let analyzed = try await registry.run(DatabaseMaintenanceService.analyzeTaskIdentifier)
        let cleaned = try await registry.run(DatabaseMaintenanceService.cleanupTaskIdentifier)

        XCTAssertFalse(analyzed)
        XCTAssertFalse(cleaned)
        let askCount = await readiness.askCount
        XCTAssertEqual(askCount, 2, "Each handler asks for persistence before anything else")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path),
            "A handler whose persistence is not ready must not start the store's load"
        )
        XCTAssertEqual(sweep.count, 0)
        withExtendedLifetime(service) {}
    }

    // Revert-check: the `coreDataStack.isStoreLoaded` guard in
    // `DatabaseMaintenanceService.performAnalyze` (then the one in
    // `performCleanupWhileStoreIsIdle`). Without it the task's first touch of the lazy
    // container starts the store's load, which this unopenable store latches as a
    // failure. The cleanup then stops at the attached-store check.
    func testHandlers_readyButStoreNotLoaded_returnFalseWithoutStartingTheLoad() async throws {
        let storeURL = try TestCoreDataStack.makeUnopenableSQLiteStore()
        directoriesToRemove.append(storeURL.deletingLastPathComponent())
        let stack = CoreDataStack(
            unloadedPersistentContainerForTesting: TestCoreDataStack.makeUnloadedSQLiteContainer(storeURL: storeURL)
        )
        let registry = CapturingTaskRegistry()
        let sweep = SweepRecorder()
        let service = makeService(registry: registry, stack: stack, readiness: { true }, sweep: sweep)

        let analyzed = try await registry.run(DatabaseMaintenanceService.analyzeTaskIdentifier)
        XCTAssertFalse(analyzed)
        try await assertNoLoadWasAttempted(stack)

        let cleaned = try await registry.run(DatabaseMaintenanceService.cleanupTaskIdentifier)
        XCTAssertFalse(cleaned)
        try await assertNoLoadWasAttempted(stack)
        XCTAssertEqual(sweep.count, 0)
        withExtendedLifetime(service) {}
    }

    // HONEST SCOPE: the stack says it is loaded and has no store, as a stack built for
    // tests does, and as no production stack is known to. Reverting the attached-store
    // guard at the start of `performCleanupWhileStoreIsIdle` leaves the answer false
    // (`deleteOrphanedAttachments` asks again and throws), but sends the history purge to a
    // coordinator with no store, whose behavior there is unmeasured; that revert is not run.
    func testCleanup_flagSaysLoadedButNoStoreIsAttached_returnsFalse() async {
        let (container, storeURL) = TestCoreDataStack.makeStorelessContainer()
        directoriesToRemove.append(storeURL.deletingLastPathComponent())
        let sweep = SweepRecorder()
        let service = makeService(
            stack: CoreDataStack(persistentContainerForTesting: container),
            readiness: { true },
            sweep: sweep
        )

        let cleaned = await service.performCleanup()

        XCTAssertFalse(cleaned)
        XCTAssertTrue(container.persistentStoreCoordinator.persistentStores.isEmpty)
        XCTAssertEqual(sweep.count, 0)
    }

    /// The control for the refusals above: with a loaded store, the same injected run,
    /// boundary and sweep run both tasks to the end, so a refusal is the guard's and not
    /// the harness's.
    func testHandlers_loadedStore_runToTheEnd() async throws {
        let testStack = TestCoreDataStack(storeKind: .sqlite)
        let registry = CapturingTaskRegistry()
        let sweep = SweepRecorder()
        let service = makeService(
            registry: registry,
            stack: CoreDataStack(persistentContainerForTesting: testStack.persistentContainer),
            readiness: { true },
            sweep: sweep
        )
        let orphanBody = try XCTUnwrap(service.htmlContentHandler().saveHTML("<p>orphan</p>", for: "orphan"))

        let analyzed = try await registry.run(DatabaseMaintenanceService.analyzeTaskIdentifier)
        let cleaned = try await registry.run(DatabaseMaintenanceService.cleanupTaskIdentifier)

        XCTAssertTrue(analyzed)
        XCTAssertTrue(cleaned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanBody.path))
        XCTAssertEqual(sweep.count, 1)
        withExtendedLifetime(service) {}
    }

    // MARK: - Helpers

    private func makeService(
        registry: CapturingTaskRegistry? = nil,
        stack: CoreDataStack,
        readiness: @escaping @Sendable () async -> Bool,
        sweep: SweepRecorder
    ) -> DatabaseMaintenanceService {
        let messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseMaintenanceStoreGateTests-\(UUID().uuidString)", isDirectory: true)
        directoriesToRemove.append(messagesDirectory)
        let htmlContentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        return DatabaseMaintenanceService(
            taskRegistry: registry ?? CapturingTaskRegistry(),
            coreDataStack: stack,
            persistenceReadiness: readiness,
            storeMaintenanceCoordinator: StoreMaintenanceCoordinator(
                syncRunCoordinator: SyncRunCoordinator(),
                // Not the shared provider: a flag turned off there would make every
                // refusal here pass without reaching its guard.
                remoteConfig: StaticRemoteConfigProvider(flags: [.databaseMaintenanceEnabled: true])
            ),
            htmlContentHandler: { htmlContentHandler },
            sweepOrphanedAttachmentFiles: { sweep.record() }
        )
    }

    /// A load that was started on the unopenable store latches its failure; one that was
    /// never started leaves nothing latched, and the wait times out.
    private func assertNoLoadWasAttempted(
        _ stack: CoreDataStack,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            try await stack.waitForStoreToLoad(timeout: 0)
            XCTFail("The store must not have loaded", file: file, line: line)
        } catch CoreDataError.storeLoadFailed(let underlying) {
            XCTAssertFalse(
                underlying is PersistentStoreLoadError,
                "The handler started the store's load: \(underlying)",
                file: file,
                line: line
            )
        }
    }
}

/// Counts the attachment sweeps the cleanup asked for, in place of the real one.
private final class SweepRecorder: @unchecked Sendable {
    /// `@unchecked Sendable`: `lock` guards `recorded`.
    private let lock = NSLock()
    private var recorded = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record() {
        lock.lock()
        recorded += 1
        lock.unlock()
    }
}

/// Counts the readiness asks and gives one answer.
private actor ReadinessProbe {
    private let answer: Bool
    private(set) var askCount = 0

    init(answer: Bool) {
        self.answer = answer
    }

    func ask() -> Bool {
        askCount += 1
        return answer
    }
}

/// Keeps the handlers it is given, so a test can run one as the system would.
private final class CapturingTaskRegistry: BackgroundTaskRegistering {
    private var handlers: [String: () async -> Bool] = [:]

    func register(config: BackgroundTaskConfiguration, handler: @escaping () async -> Bool) {
        handlers[config.identifier] = handler
    }

    func scheduleIfNotPending(_ identifiers: [String]) async {}

    func retire(_ identifier: String) {}

    func run(_ identifier: String) async throws -> Bool {
        let handler = try XCTUnwrap(handlers[identifier], "No handler registered for \(identifier)")
        return await handler()
    }
}
