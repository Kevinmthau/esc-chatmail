import CoreData
import Foundation

protocol RichContentVerdictRefreshing: Sendable {
    /// Recomputes and stores the rich-content verdict of the rows with this message ID, in
    /// the background. Returns at once; callers never wait for the write.
    func scheduleRefresh(messageID: String, handler: HTMLContentHandler)
}

/// Re-stamps `Message.richContentVerdict` for one message whose stored state changed outside
/// sync, or whose stored verdict a bubble load contradicted.
///
/// Sync stamps the verdict whenever it writes a row (`MessagePersister.stampRichContentVerdict`).
/// Two other writers put HTML on disk for an existing row, and each schedules a refresh after
/// a successful save: `HTMLContentRecoveryService` (HTML fetched from Gmail, which can also
/// replace an existing file) and `CanonicalEmailContentLoader` (HTML extracted from a
/// raw-source body). Without it such a row keeps the verdict of the state it had before, and
/// a stored "not rich" then renders its text at mount and swaps to a card when the load
/// publishes, on every open.
///
/// The bubble loader is the catch-all (`MessageBubbleLoader.loadContent`): a completed load
/// whose verdict differs from the row's stored one schedules a refresh too. That covers every
/// way a stored verdict can be missing or stale without passing a save site: a row the launch
/// backfill has not reached, a refresh that was refused or lost, a `bodyStorageURI` written by
/// the reader (`FullEmailOpenSession`), a classifier change shipped without an epoch bump.
///
/// A refresh never takes a verdict from its caller. It recomputes
/// `RichContentVerdictResolver.verdict` from the row's stored state under its own lease, so a
/// caller's transient answer cannot be persisted, and a refresh scheduled for one account
/// that runs after a transition evaluates only what the current account stores.
///
/// Stateless, so not an account-generation participant: the non-exclusive account work lease
/// is held from before the first read to after the save, and teardown drains leases before it
/// closes HTML storage or replaces the store. There is no `isActiveRun` re-check after the
/// suspensions inside the lease, unlike `MessageActions`: a granted lease is only ever
/// removed by its holder's `endRun`, so the check cannot fail here, and nothing on this
/// path could act on it. If this ever gains state (a pending set, coalescing tasks, a memo),
/// it becomes a participant and must be wired into `AuthSession`.
final class RichContentVerdictRefresher: RichContentVerdictRefreshing {
    enum Outcome: Equatable, Sendable {
        /// A row's stored verdict was changed and saved.
        case updated
        /// Nothing was written: every row already holds the recomputed verdict, was rewritten
        /// or deleted while this classified, or no row has this ID any more.
        case unchanged
        /// The stored state could not be read, so nothing was written.
        case undetermined
        /// No lease (teardown, or the refresher is inert), a failed fetch, or a failed save.
        case skipped
    }

    /// Inert under hosted unit tests: the services that default to it are constructed by many
    /// suites against temporary HTML directories, and a live shared instance would take
    /// leases on `SyncRunCoordinator.shared` and read the test host's real store after each
    /// of their saves. Suites that exercise a refresh inject their own.
    static let shared: RichContentVerdictRefresher = RuntimeEnvironment.isRunningUnitTests
        ? RichContentVerdictRefresher(isEnabled: false)
        : RichContentVerdictRefresher()

    private let accountWorkCoordinator: SyncRunCoordinator
    private let makeBackgroundContext: @Sendable () -> NSManagedObjectContext
    private let isEnabled: Bool

    /// - Parameter makeBackgroundContext: must return a context with the stack's object-trump
    ///   merge policy (`CoreDataStack.newBackgroundContext()`): this write is the freshest
    ///   evaluation of the row, and under store-trump it would lose to the launch backfill's
    ///   older value whenever the two overlapped.
    init(
        accountWorkCoordinator: SyncRunCoordinator = .shared,
        makeBackgroundContext: @escaping @Sendable () -> NSManagedObjectContext = {
            CoreDataStack.shared.newBackgroundContext()
        },
        isEnabled: Bool = true
    ) {
        self.accountWorkCoordinator = accountWorkCoordinator
        self.makeBackgroundContext = makeBackgroundContext
        self.isEnabled = isEnabled
    }

    /// Detached, at utility priority, for three reasons. Both HTML save sites call this
    /// right after the `invalidateContent` that cancels the task they are running in (a
    /// rendered-cache producer), so inherited cancellation would silently drop the refresh
    /// for exactly the rows whose HTML just changed. The recovery save site runs on the
    /// `HTMLContentRecoveryService` actor, whose executor must not run a DOM classification.
    /// And the refresh holds an account work lease, which sign-out waits on: background
    /// priority can sit unscheduled long enough to stall it.
    func scheduleRefresh(messageID: String, handler: HTMLContentHandler) {
        guard isEnabled else { return }
        Task.detached(priority: .utility) { [self] in
            await refresh(messageID: messageID, handler: handler)
        }
    }

    @discardableResult
    func refresh(messageID: String, handler: HTMLContentHandler) async -> Outcome {
        guard isEnabled,
              let request = await accountWorkCoordinator.makeAccountWorkRequest(),
              let lease = await accountWorkCoordinator.acquireAccountWorkLease(
                  kind: .maintenance,
                  for: request
              ) else {
            return .skipped
        }

        // Every exit goes through this one release: sign-out waits for outstanding leases
        // and cannot cancel them, so a leaked lease hangs every later account transition.
        let outcome = await refreshHoldingLease(messageID: messageID, handler: handler)
        await accountWorkCoordinator.endRun(lease)
        return outcome
    }

    private struct RowSnapshot: Sendable {
        let objectID: NSManagedObjectID
        let inputs: RichContentVerdictInputs
    }

    private func refreshHoldingLease(messageID: String, handler: HTMLContentHandler) async -> Outcome {
        let context = makeBackgroundContext()

        // Duplicate rows for one ID can exist transiently, so every match is refreshed.
        let snapshots: [RowSnapshot]? = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(messageID)
            do {
                return try context.fetch(request).map {
                    RowSnapshot(objectID: $0.objectID, inputs: $0.richContentVerdictInputs)
                }
            } catch {
                Log.error("Rich content verdict refresh could not read the message", category: .coreData, error: error)
                return nil
            }
        }
        guard let snapshots else { return .skipped }
        guard !snapshots.isEmpty else { return .unchanged }

        // Classify off the context's queue, so the row is not held registered across a DOM
        // cleanup, then re-read it before writing.
        guard let generation = handler.captureAccountGeneration() else { return .undetermined }
        let verdicts = snapshots.map {
            RichContentVerdictResolver.verdict(
                for: $0.inputs,
                handler: handler,
                expectedAccountGeneration: generation
            )
        }

        return await context.perform {
            context.refreshAllObjects()
            var didChange = false
            var sawUndetermined = false
            for (snapshot, verdict) in zip(snapshots, verdicts) {
                guard verdict != .unknown else {
                    sawUndetermined = true
                    continue
                }
                // A row deleted or rewritten while this classified is skipped, whoever
                // wrote it: the verdict computed above describes inputs the row no longer
                // has. Sync stamps its own write in the same save. The reader's
                // `bodyStorageURI` write (`FullEmailOpenSession.updateBodyStorageURIIfNeeded`)
                // stamps nothing and is left to the bubble load, which re-runs because
                // that URI is in its load signature and schedules a fresh refresh if the
                // stored verdict is then stale. A sync save landing between this re-read
                // and the save below is not seen, and object-trump then keeps this
                // verdict over sync's; the next bubble load that disagrees heals it too.
                guard let message = try? context.existingObject(with: snapshot.objectID) as? Message,
                      !message.isDeleted,
                      message.richContentVerdictInputs == snapshot.inputs else {
                    continue
                }
                if message.storedRichContentVerdict != verdict {
                    message.storedRichContentVerdict = verdict
                    didChange = true
                }
            }

            guard didChange else { return sawUndetermined ? .undetermined : .unchanged }
            guard context.saveOrLog(operation: "refresh rich content verdict") else {
                context.rollback()
                return .skipped
            }
            return .updated
        }
    }
}
