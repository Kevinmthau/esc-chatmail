import WebKit
import XCTest
@testable import esc_chatmail

/// `EmailWebContentNetworkRules`' states: compiled once, attached once per controller, closed
/// while compiling, open (logged) once two compiles failed, and its waits bounded and
/// cancellable. Every provider here compiles into a temporary directory of its own, never WebKit's
/// default store: on the Mac that is the installed MushMail's container.
@MainActor
final class EmailWebContentNetworkRulesTests: XCTestCase {
    private func makeCompilingRules(encodedRuleList: String = EmailWebContentNetworkRuleSource.encodedRuleList) -> EmailWebContentNetworkRules {
        EmailWebContentNetworkRules(
            compile: EmailWebContentNetworkRules.storeCompiler(makeStore: EmailWebContentNetworkRules.temporaryStore),
            encodedRuleList: encodedRuleList
        )
    }

    /// A provider whose compile never ends, and the number of compiles it was asked for.
    private func makeNeverCompilingRules() -> (EmailWebContentNetworkRules, () -> Int) {
        var compiles = 0
        let rules = EmailWebContentNetworkRules(compile: { _, _, _ in compiles += 1 })
        return (rules, { compiles })
    }

    /// The production rules compile in WebKit, on every OS this suite runs on; a rule WebKit's
    /// grammar refuses (an alternation, a `{n}`) fails the whole list, which this would show.
    func testProductionRules_compile_andAttachOncePerController() async {
        let rules = makeCompilingRules()
        let permitted = await rules.waitUntilLoadingPermitted(timeoutNanoseconds: 10_000_000_000)

        XCTAssertTrue(permitted)
        XCTAssertEqual(rules.state, .ready)
        let controller = WKUserContentController()
        XCTAssertTrue(rules.attach(to: controller))
        XCTAssertTrue(rules.isAttached(to: controller))
        XCTAssertTrue(rules.attach(to: controller))
    }

    /// The unit-test host's shared provider has compiled before any test runs (`esc_chatmailApp`
    /// waits for it there), so suites that load web views synchronously never see it compiling.
    func testSharedRules_areReadyInTheTestHost() {
        XCTAssertEqual(EmailWebContentNetworkRules.shared.state, .ready)
    }

    /// While compiling, nothing may load: `attach` says no and attaches nothing, and a callback
    /// asked for then waits.
    ///
    /// Revert-check: making `attach(to:)` answer true for `.compiling` fails this.
    func testWhileCompiling_attachRefuses_andCallbacksWait() {
        let (rules, compiles) = makeNeverCompilingRules()
        let controller = WKUserContentController()
        var callbacks = 0

        XCTAssertFalse(rules.attach(to: controller))
        XCTAssertFalse(rules.isAttached(to: controller))
        XCTAssertFalse(rules.permitsLoading)
        rules.notifyWhenLoadingPermitted { callbacks += 1 }

        XCTAssertEqual(rules.state, .compiling)
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(compiles(), 1, "prepare() compiles once, however often it is asked")
    }

    /// A callback asked for while compiling runs once the list is ready, and one asked for after
    /// runs at once.
    func testCallbacks_runOnceCompiled() async {
        let rules = makeCompilingRules()
        var callbacks = 0
        rules.notifyWhenLoadingPermitted { callbacks += 1 }
        XCTAssertEqual(callbacks, 0)

        _ = await rules.waitUntilLoadingPermitted(timeoutNanoseconds: 10_000_000_000)
        XCTAssertEqual(callbacks, 1)

        rules.notifyWhenLoadingPermitted { callbacks += 1 }
        XCTAssertEqual(callbacks, 2)
    }

    /// A list WebKit refuses twice leaves the provider unavailable, which fails open: web views
    /// load without it rather than never.
    func testRefusedCompile_twice_failsOpen() async {
        let rules = makeCompilingRules(encodedRuleList: #"[{"trigger":{"url-filter":"(a|b)"},"action":{"type":"block"}}]"#)
        var callbacks = 0
        rules.notifyWhenLoadingPermitted { callbacks += 1 }

        let permitted = await rules.waitUntilLoadingPermitted(timeoutNanoseconds: 10_000_000_000)

        XCTAssertTrue(permitted)
        XCTAssertEqual(rules.state, .unavailable)
        XCTAssertEqual(callbacks, 1)
        let controller = WKUserContentController()
        XCTAssertTrue(rules.attach(to: controller))
        XCTAssertFalse(rules.isAttached(to: controller))
    }

    /// An empty list would compile and block nothing; it is treated as a failed compile.
    func testEmptyRuleList_isNeverReady() async {
        let rules = makeCompilingRules(encodedRuleList: "[]")
        _ = await rules.waitUntilLoadingPermitted(timeoutNanoseconds: 10_000_000_000)
        XCTAssertEqual(rules.state, .unavailable)
    }

    /// The wait the snapshot renderer takes ends at its bound, and at once when its task is
    /// cancelled, as an account transition's close of the renderer cancels it.
    ///
    /// Revert-check: removing the `onCancel` resume in `waitUntilLoadingPermitted` makes the
    /// cancelled wait last until its 30 s bound and fails the elapsed-time assertion.
    func testWait_endsAtItsBound_andAtOnceOnCancellation() async {
        let (rules, _) = makeNeverCompilingRules()

        let timedOut = await rules.waitUntilLoadingPermitted(timeoutNanoseconds: 50_000_000)
        XCTAssertFalse(timedOut)

        let wait = Task { @MainActor in
            await rules.waitUntilLoadingPermitted(timeoutNanoseconds: 30_000_000_000)
        }
        await Task.yield()
        let start = Date()
        wait.cancel()
        let cancelledResult = await wait.value
        XCTAssertFalse(cancelledResult)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// A compile that failed is tried again, at most once a `retryInterval`, by the next web view
    /// that asks, so a transient refusal (a full disk) does not leave the rest of the process
    /// without the list. While the retry runs, loading is closed again, so no view loads without
    /// the list in the window before it is ready; its callbacks re-drive the waiting loads.
    ///
    /// Revert-check: removing `retryIfDue()` from `prepare()` leaves the provider unavailable after
    /// the clock has moved and fails this; dropping `!isRetryingAfterFailure` from `attach(to:)`'s
    /// `.unavailable` case fails the in-flight assertion.
    func testFailedCompile_isRetriedOnceTheIntervalHasPassed_andClosesLoadingWhileItRuns() async {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var calls = 0
        let realCompile = EmailWebContentNetworkRules.storeCompiler(
            makeStore: EmailWebContentNetworkRules.temporaryStore
        )
        let rules = EmailWebContentNetworkRules(
            compile: { identifier, list, completion in
                calls += 1
                // The first two compiles (one failure cycle) are refused; later ones compile.
                if calls <= 2 {
                    completion(nil, CocoaError(.fileWriteOutOfSpace))
                } else {
                    realCompile(identifier, list, completion)
                }
            },
            retryInterval: 60,
            now: { clock }
        )

        let firstPermitted = await rules.waitUntilLoadingPermitted(timeoutNanoseconds: 10_000_000_000)
        XCTAssertTrue(firstPermitted)
        XCTAssertEqual(rules.state, .unavailable)
        XCTAssertEqual(calls, 2)

        clock.addTimeInterval(30)
        XCTAssertTrue(rules.attach(to: WKUserContentController()))
        XCTAssertEqual(calls, 2, "No retry before the interval")

        clock.addTimeInterval(31)
        var callbacks = 0
        XCTAssertFalse(
            rules.attach(to: WKUserContentController()),
            "A retry in flight closes loading until it ends"
        )
        rules.notifyWhenLoadingPermitted { callbacks += 1 }
        XCTAssertEqual(calls, 3)

        let deadline = Date().addingTimeInterval(10)
        while rules.state != .ready, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(rules.state, .ready)
        XCTAssertEqual(callbacks, 1, "The retry's end re-drives a load that waited for it")
        let controller = WKUserContentController()
        XCTAssertTrue(rules.attach(to: controller))
        XCTAssertTrue(rules.isAttached(to: controller))
    }

    /// A compile that never answers counts as failed once `compileTimeout` passes, so a WebKit
    /// that never calls back cannot hold every web view for the rest of the process; a late answer
    /// of an attempt already given up is ignored.
    ///
    /// Revert-check: removing the `scheduleCompileTimeout` call from `startCompile` leaves the
    /// provider compiling and fails this.
    func testCompileThatNeverAnswers_failsAtItsTimeout_andALateAnswerIsIgnored() async {
        var completions: [@Sendable (WKContentRuleList?, Error?) -> Void] = []
        var timeouts: [@MainActor () -> Void] = []
        let rules = EmailWebContentNetworkRules(
            compile: { _, _, completion in completions.append(completion) },
            compileTimeout: 10,
            scheduleCompileTimeout: { _, action in timeouts.append(action) }
        )

        rules.prepare()
        XCTAssertEqual(rules.state, .compiling)
        XCTAssertEqual(timeouts.count, 1)

        timeouts[0]()
        XCTAssertEqual(completions.count, 2, "The timed-out attempt counts; the second one starts")
        XCTAssertEqual(rules.state, .compiling)
        timeouts[1]()

        XCTAssertEqual(rules.state, .unavailable)
        XCTAssertTrue(rules.permitsLoading)

        let lateList = try? await compileRealList()
        completions[0](lateList, nil)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rules.state, .unavailable, "An answer of an attempt given up is ignored")
    }

    private func compileRealList() async throws -> WKContentRuleList {
        let store = try XCTUnwrap(EmailWebContentNetworkRules.temporaryStore())
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: "late-\(UUID().uuidString)",
                encodedContentRuleList: EmailWebContentNetworkRuleSource.encodedRuleList
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }
}
