import Foundation
import WebKit

/// Compiles `EmailWebContentNetworkRuleSource`'s rule list once per launch and attaches it to
/// every web view that renders email HTML: the full reader and the pool that pre-renders it
/// (`FullInteractiveEmailWebView.makeConfiguration`), the preview web view (`BaseEmailWebView`),
/// the snapshot renderer's session and the debug renderer.
///
/// Compiling is asynchronous and a web view is made synchronously, so a web view can exist before
/// the list does. It fails closed while the list compiles: `attach(to:)` answers false, and
/// nothing loads email HTML into a web view it answered false for. The reader's and the preview's
/// coordinators defer their load (`network-rules-pending`) and load when this calls them back, the
/// pool pre-renders nothing (and so never hands out a view warmed without the list), and the
/// snapshot renderer waits, bounded and cancellably, before it builds its session. A list added to
/// a web view's user content controller before its first load blocks that load (measured on the
/// iOS 27.0 simulator), so a web view made while the list compiled is covered once it is attached.
///
/// A compile that fails twice leaves the list unavailable, and web views then load without it
/// (logged at error). That fails open on purpose: the rules are fixed and a test compiles them on
/// both platforms CI runs (`EmailWebContentNetworkRulesTests` is in the default plan and in
/// `Mac.xctestplan`), so what is left is a WebKit or a disk that refuses the compile, and failing
/// closed there would leave every HTML email unreadable to stop requests whose answers no script
/// can read. A compile that does not answer within `compileTimeout` counts as failed, so a WebKit
/// that never calls back cannot hold every web view for the rest of the process. A refusal may pass
/// (a disk that was full), so the next web view that asks at least `retryInterval` after it
/// compiles again; while that retry runs, loading is closed again (its callbacks re-drive the
/// waiting loads when it ends, in milliseconds), so no view loads without the list in the window
/// before it is ready. A view made while the list was unavailable keeps loading without it, and the
/// pool does not hand out such a view once the list is ready (`FullEmailWebViewManager.checkout`).
///
/// The list is the app's, not an account's, so it is no participant of the account boundary. A
/// callback waiting for it holds its coordinator weakly, and an invalidated coordinator loads
/// nothing when it runs.
///
/// Production compiles into WebKit's default store under a fixed identifier, which each launch
/// overwrites, so a list another build stored is never looked up. The unit-test host compiles into
/// a temporary directory of its own: the Mac test host's container is the installed MushMail's.
@MainActor
final class EmailWebContentNetworkRules {
    static let shared = EmailWebContentNetworkRules(
        compile: storeCompiler(
            makeStore: RuntimeEnvironment.isRunningUnitTests
                ? EmailWebContentNetworkRules.temporaryStore
                : { WKContentRuleListStore.default() }
        )
    )

    /// Compiles `encodedRuleList` under `identifier` and calls back once, on any thread. A seam
    /// so tests can hold a compile in flight; production is `storeCompiler`.
    typealias Compile = @MainActor (
        _ identifier: String,
        _ encodedRuleList: String,
        _ completion: @escaping @Sendable (WKContentRuleList?, Error?) -> Void
    ) -> Void

    enum State: Equatable {
        case notStarted
        case compiling
        case ready
        /// Two compiles failed; web views load without the list until a retry compiles it.
        case unavailable
    }

    static let identifier = "EmailWebContentPrivateNetworkRules"

    private let compileRuleList: Compile
    private let encodedRuleList: String
    private let maximumCompileAttempts: Int
    private let retryInterval: TimeInterval
    private let compileTimeout: TimeInterval
    private let scheduleCompileTimeout: ScheduleTimeout
    private let now: @MainActor () -> Date
    /// Bumped by every compile attempt, so an answer (or a timeout) of an attempt that already
    /// ended is ignored.
    private var compileAttemptToken = 0

    /// Runs `action` once after `interval`; a seam so a test can fire the timeout itself.
    typealias ScheduleTimeout = @MainActor (_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

    static let sleepingTimeout: ScheduleTimeout = { interval, action in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            action()
        }
    }
    private(set) var state: State = .notStarted
    private var ruleList: WKContentRuleList?
    private var compileAttempts = 0
    private var lastFailureAt: Date?
    /// A compile started from `.unavailable`, which leaves loading open while it runs.
    private var isRetryingAfterFailure = false
    /// The controllers the list was added to, so it is added once. Weak: a controller lives as long
    /// as its web view.
    private let attachedControllers = NSHashTable<WKUserContentController>.weakObjects()
    private var loadingPermittedCallbacks: [@MainActor () -> Void] = []
    private var loadingPermittedWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(
        compile: @escaping Compile,
        encodedRuleList: String = EmailWebContentNetworkRuleSource.encodedRuleList,
        maximumCompileAttempts: Int = 2,
        retryInterval: TimeInterval = 60,
        compileTimeout: TimeInterval = 10,
        scheduleCompileTimeout: ScheduleTimeout? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.compileRuleList = compile
        self.encodedRuleList = encodedRuleList
        self.maximumCompileAttempts = max(1, maximumCompileAttempts)
        self.retryInterval = retryInterval
        self.compileTimeout = compileTimeout
        self.scheduleCompileTimeout = scheduleCompileTimeout ?? Self.sleepingTimeout
        self.now = now
    }

    /// Compiles into the store `makeStore` gives, made once, on the first compile. No store is a
    /// failed compile.
    static func storeCompiler(makeStore: @escaping @MainActor () -> WKContentRuleListStore?) -> Compile {
        var store: WKContentRuleListStore?
        return { identifier, encodedRuleList, completion in
            if store == nil {
                store = makeStore()
            }
            guard let store else {
                completion(nil, nil)
                return
            }
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: encodedRuleList
            ) { ruleList, error in
                completion(ruleList, error)
            }
        }
    }

    /// A store in a new directory under the temporary directory, for the unit-test host and tests.
    static func temporaryStore() -> WKContentRuleListStore? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmailWebContentNetworkRules-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: directory)
    }

    /// True once a web view may load email HTML: the list is compiled, or it could not be and no
    /// retry is running.
    var permitsLoading: Bool {
        state == .ready || (state == .unavailable && !isRetryingAfterFailure)
    }

    /// Starts the compile, once, and again after a failure once `retryInterval` has passed. The
    /// app calls it at launch so the list is ready before the first web view; `attach(to:)` and
    /// the waits call it too.
    func prepare() {
        switch state {
        case .notStarted:
            state = .compiling
            compileAttempts = 0
            startCompile()
        case .unavailable:
            retryIfDue()
        case .compiling, .ready:
            return
        }
    }

    private func retryIfDue() {
        guard !isRetryingAfterFailure,
              let lastFailureAt,
              now().timeIntervalSince(lastFailureAt) >= retryInterval else {
            return
        }
        isRetryingAfterFailure = true
        compileAttempts = 0
        startCompile()
    }

    /// Adds the list to `controller` if it is compiled and was not added yet. True when a web view
    /// with this controller may load email HTML; false while the list is still compiling, when the
    /// caller must not load and should ask again from `notifyWhenLoadingPermitted`.
    @discardableResult
    func attach(to controller: WKUserContentController) -> Bool {
        prepare()
        switch state {
        case .ready:
            guard let ruleList else { return false }
            if !attachedControllers.contains(controller) {
                controller.add(ruleList)
                attachedControllers.add(controller)
            }
            return true
        case .unavailable:
            return !isRetryingAfterFailure
        case .notStarted, .compiling:
            return false
        }
    }

    func isAttached(to controller: WKUserContentController) -> Bool {
        attachedControllers.contains(controller)
    }

    /// Runs `action` once loading is permitted: now if it already is, else when the compile ends.
    func notifyWhenLoadingPermitted(_ action: @escaping @MainActor () -> Void) {
        prepare()
        guard !permitsLoading else {
            action()
            return
        }
        loadingPermittedCallbacks.append(action)
    }

    /// Waits until loading is permitted, at most `timeoutNanoseconds`, and answers whether it is.
    /// Cancellation ends the wait at once with false, so a caller inside an account boundary's
    /// drain (the snapshot renderer's operation) never holds the drain up.
    func waitUntilLoadingPermitted(timeoutNanoseconds: UInt64) async -> Bool {
        prepare()
        guard !permitsLoading else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled, !permitsLoading else {
                    continuation.resume(returning: permitsLoading && !Task.isCancelled)
                    return
                }
                loadingPermittedWaiters[id] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.resumeWaiter(id, returning: false)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeWaiter(id, returning: false)
            }
        }
    }

    private func resumeWaiter(_ id: UUID, returning value: Bool) {
        loadingPermittedWaiters.removeValue(forKey: id)?.resume(returning: value)
    }

    private func startCompile() {
        compileAttempts += 1
        compileAttemptToken &+= 1
        let attempt = compileAttemptToken
        // A list of no rules compiles and blocks nothing, which would read as ready.
        guard encodedRuleList != "[]" else {
            compileDidFail(error: nil)
            return
        }
        scheduleCompileTimeout(compileTimeout) { [weak self] in
            guard let self, self.compileAttemptToken == attempt else { return }
            Log.warning("Email web content network rules compile did not answer in time", category: .ui)
            self.compileDidFail(error: nil)
        }
        compileRuleList(Self.identifier, encodedRuleList) { [weak self] ruleList, error in
            // WebKit calls back on the main thread; the hop says so to the compiler instead of
            // trapping if a WebKit ever did not.
            Task { @MainActor [weak self] in
                guard let self, self.compileAttemptToken == attempt else { return }
                self.compileDidEnd(ruleList: ruleList, error: error)
            }
        }
    }

    private func compileDidEnd(ruleList: WKContentRuleList?, error: Error?) {
        guard let ruleList, error == nil else {
            compileDidFail(error: error)
            return
        }
        compileAttemptToken &+= 1
        self.ruleList = ruleList
        state = .ready
        isRetryingAfterFailure = false
        Log.diagnostic(
            .htmlPreview,
            level: .info,
            "Email web content network rules compiled attempts=\(compileAttempts)",
            category: .ui
        )
        loadingDidBecomePermitted()
    }

    private func compileDidFail(error: Error?) {
        guard compileAttempts >= maximumCompileAttempts else {
            startCompile()
            return
        }
        compileAttemptToken &+= 1
        state = .unavailable
        lastFailureAt = now()
        isRetryingAfterFailure = false
        Log.error(
            "Email web content network rules did not compile; web views load without them until a retry compiles them",
            category: .ui,
            error: error
        )
        loadingDidBecomePermitted()
    }

    private func loadingDidBecomePermitted() {
        let callbacks = loadingPermittedCallbacks
        loadingPermittedCallbacks.removeAll()
        let waiters = loadingPermittedWaiters
        loadingPermittedWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: true)
        }
        for callback in callbacks {
            callback()
        }
    }
}
