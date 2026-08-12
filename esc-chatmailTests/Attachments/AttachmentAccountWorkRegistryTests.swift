import XCTest
@testable import esc_chatmail

@MainActor
final class AttachmentAccountWorkRegistryTests: XCTestCase {
    func testTeardownCancelsAndAwaitsUncooperativeWriterBeforeReopen() async throws {
        let registry = AttachmentAccountWorkRegistry(admissionOpen: true)
        let writerGate = AttachmentAccountWorkGate()
        let staleWrite = AttachmentAccountWorkFlag()
        let unresolvedArtifactsCleaned = AttachmentAccountWorkFlag()
        let teardownFinished = AttachmentAccountWorkFlag()

        let writerTask = try XCTUnwrap(registry.startOperation { generation in
            await writerGate.waitUntilReleased()
            guard generation.isActive else {
                // Picker operations perform placeholder/file cleanup on this
                // path before returning ownership to the registry.
                unresolvedArtifactsCleaned.set()
                return
            }
            staleWrite.set()
        })
        await writerGate.waitUntilStarted()

        let teardownTask = Task { @MainActor in
            await registry.cancelAndAwaitAll()
            teardownFinished.set()
        }
        while registry.captureAdmissionToken() != nil {
            await Task.yield()
        }

        XCTAssertFalse(
            teardownFinished.isSet,
            "Account teardown must await a picker/file operation that ignores task cancellation"
        )
        XCTAssertNil(
            registry.startOperation { _ in },
            "No old-account attachment writer may start after teardown closes admission"
        )

        await writerGate.release()
        await teardownTask.value
        await writerTask.value

        XCTAssertFalse(staleWrite.isSet)
        XCTAssertTrue(
            unresolvedArtifactsCleaned.isSet,
            "Teardown must not finish before cancelled picker artifacts are unwound"
        )
        XCTAssertTrue(teardownFinished.isSet)

        XCTAssertTrue(registry.reopenAdmission())
        let newWrite = AttachmentAccountWorkFlag()
        let newTask = try XCTUnwrap(registry.startOperation { generation in
            guard generation.isActive else { return }
            newWrite.set()
        })
        await newTask.value
        XCTAssertTrue(newWrite.isSet)
    }

    func testTeardownCancelsAndDrainsDetachedFileWriter() async throws {
        let registry = AttachmentAccountWorkRegistry(admissionOpen: true)
        let writerGate = AttachmentAccountWorkGate()
        let cleanupFinished = AttachmentAccountWorkFlag()
        let teardownFinished = AttachmentAccountWorkFlag()

        let writerTask = try XCTUnwrap(registry.startDetachedOperation { generation in
            await writerGate.waitUntilReleased()
            guard !generation.isActive else { return }
            cleanupFinished.set()
        })
        await writerGate.waitUntilStarted()

        let teardownTask = Task { @MainActor in
            await registry.cancelAndAwaitAll()
            teardownFinished.set()
        }
        while registry.captureAdmissionToken() != nil {
            await Task.yield()
        }
        XCTAssertFalse(teardownFinished.isSet)

        await writerGate.release()
        await teardownTask.value
        await writerTask.value

        XCTAssertTrue(cleanupFinished.isSet)
        XCTAssertTrue(teardownFinished.isSet)
    }

    // Revert-check: fails if `reopenAdmission()`'s
    // `guard operations.isEmpty else { return false }` is removed or downgraded
    // to an unconditional reopen. Admission would then reopen on top of a still
    // live old-account writer, whose late file or Core Data write would land in
    // the next account's store.
    //
    // HONEST SCOPE: the outstanding operation is manufactured by holding the
    // writer gate. AuthSession always drains through `cancelAndAwaitAll()`
    // before reopening, so this state is unreachable through the account
    // transition paths today; the assertion pins the guard and its Bool result
    // against a future leak, not a live regression.
    func testReopenAdmissionRefusesWhileClosedAccountWriterIsOutstanding() async throws {
        let registry = AttachmentAccountWorkRegistry(admissionOpen: true)
        let writerGate = AttachmentAccountWorkGate()

        let writerTask = try XCTUnwrap(registry.startOperation { _ in
            await writerGate.waitUntilReleased()
        })
        await writerGate.waitUntilStarted()

        XCTAssertFalse(
            registry.reopenAdmission(),
            "Admission must stay closed while an old-account writer is still live"
        )

        await writerGate.release()
        await writerTask.value

        XCTAssertTrue(
            registry.reopenAdmission(),
            "Admission must reopen once every old-account writer has unwound"
        )
    }

    func testStaleAdmissionTokenCannotRegisterAfterCloseAndReopen() async throws {
        let registry = AttachmentAccountWorkRegistry(admissionOpen: true)
        let staleAdmission = try XCTUnwrap(registry.captureAdmissionToken())

        await registry.cancelAndAwaitAll()
        XCTAssertTrue(registry.reopenAdmission())

        let staleWork = AttachmentAccountWorkFlag()
        XCTAssertNil(
            registry.startDetachedOperation(for: staleAdmission) { _ in
                staleWork.set()
            }
        )
        XCTAssertFalse(staleWork.isSet)

        let currentAdmission = try XCTUnwrap(registry.captureAdmissionToken())
        let currentWork = AttachmentAccountWorkFlag()
        let currentTask = try XCTUnwrap(
            registry.startDetachedOperation(for: currentAdmission) { generation in
                guard generation.isActive else { return }
                currentWork.set()
            }
        )
        await currentTask.value

        XCTAssertTrue(currentWork.isSet)
    }
}

private actor AttachmentAccountWorkGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class AttachmentAccountWorkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
