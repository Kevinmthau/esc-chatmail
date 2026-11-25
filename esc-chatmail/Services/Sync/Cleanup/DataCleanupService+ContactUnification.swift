import Foundation
import CoreData

// MARK: - One Chat Per Contact

extension DataCleanupService {

    /// Makes a person who writes from two addresses one chat, when their
    /// contact card lists both (`ContactLinkedAddresses`).
    ///
    /// New mail is routed that way by `makeParticipantSetIdentity`. This pass
    /// is for what is already stored: it adopts the linked addresses Contacts
    /// give now and, when they differ from the ones last applied, gives every
    /// conversation that names a changed address its new hash and merges the
    /// active ones that came to share one.
    ///
    /// It runs first in a sync run's cleanup (after an incremental sync has
    /// saved its mail, and before the first initial sync routes any), and that
    /// position is the point of it. The run owns the store, so nothing is
    /// routing mail; the cleanup-sensitive gate is held, so no optimistic send
    /// is hashing; and every later pass of the hold hashes with the map adopted
    /// here. Adopting anywhere else lets something hash with the new map
    /// before the stored conversations carry its hashes, and that mail opens a
    /// second chat.
    ///
    /// What was applied is kept as the map itself and not as a flag
    /// (`ContactLinkedAddressStore.appliedToConversations`), because the pass
    /// needs to know which addresses changed: it reads only the conversations
    /// that name one. It is recorded only when the pass completed. A fetch or
    /// save that failed, aliases not yet known, or an anchored conversation
    /// the pass could not finish all leave it as it was, so the next sync's
    /// cleanup tries again; the same pass run twice changes nothing the
    /// second time.
    ///
    /// Meanwhile new mail is already routed by the adopted map, so a
    /// conversation left on its old hash loses its mail to a second chat.
    /// That is why a conversation a pending send or a saved reply draft
    /// anchors still takes its new hash here, in place: a draft can anchor
    /// its chat for weeks. Only its rows and the merge with the chat that
    /// came to share its hash wait for the anchor's release. A conversation a
    /// chat-preview retry anchors keeps its old hash until that retry has run,
    /// because the retry finds it through the hash it recorded.
    ///
    /// Unlinking is half of what linking is. When a card stops listing an
    /// address, mail from it opens a chat of its own again, but the messages
    /// already in the shared chat stay there: this pass moves conversations,
    /// not messages.
    ///
    /// The same read adopts the user's own addresses Contacts add
    /// (`ContactLinkedAddressStore.selfAddressesSnapshot`), which every hash
    /// leaves out, and the same pass brings the stored conversations onto them:
    /// a conversation that names an address that came into or left the set is
    /// given the hash the router now makes (`SelfAddressChange`). The set was
    /// read live before; the first pass after that brings every conversation
    /// naming an address either rule took as the user's onto the new one.
    ///
    /// - Parameter knownAddresses: The account's addresses, when the caller
    ///   has them before the `Account` row is saved (the initial sync); nil
    ///   reads them from the row.
    /// - Returns: Whether it ran a repair; false when nothing had changed or
    ///   the account's addresses could not be read.
    @discardableResult
    func unifyConversationsByContactIfNeeded(
        in context: NSManagedObjectContext,
        knownAddresses: Set<String>? = nil
    ) async -> Bool {
        let known: Set<String>
        if let knownAddresses {
            known = Set(knownAddresses.map(EmailNormalizer.normalize).filter { !$0.isEmpty })
        } else if let stored = await accountAddresses(in: context) {
            known = stored
        } else {
            // A failed read is not "no account addresses": deciding, or
            // recording, a self set for none would drop this account's record.
            return false
        }
        // What the router has hashed with until now, read before the adoption:
        // after a switch of accounts it is not the applied set.
        let routedBefore = contactLinkStore.selfAddressesSnapshot(forKnown: known)
        let links = contactLinkStore.refreshIfNeeded(knownAddresses: known)
        let applied = contactLinkStore.appliedToConversations()
        let selfAddresses = contactLinkStore.selfAddressesSnapshot(forKnown: known)
        // With no account addresses (no Account row yet) there is no self set
        // to decide or record; the links are still applied.
        let selfChange = known.isEmpty ? SelfAddressChange.none : SelfAddressChange(
            applied: contactLinkStore.appliedSelfAddresses(forKnown: known),
            routedBefore: routedBefore,
            current: selfAddresses,
            knownAddresses: known,
            legacyOfLastRead: contactLinkStore.legacySelfAddressesOfLastRead()
        )
        // The steady state, and the whole pass without Contacts access: a few
        // comparisons, and no conversation read.
        guard links != applied || selfChange.needsPass else { return false }

        let changedAddresses = links.addressesLinkedDifferently(from: applied)
            .union(selfChange.changedAddresses)
        let outcome = await fixAndMergeIncorrectParticipantHashes(
            in: context,
            scope: .conversationsNaming(changedAddresses)
        )

        switch outcome {
        case .completed:
            contactLinkStore.markAppliedToConversations(links)
            if selfChange.isRecordable {
                contactLinkStore.markSelfAddressesApplied(selfAddresses, knownAddresses: known)
            }
            Log.info(
                "Applied contact-linked addresses to conversations (\(changedAddresses.count) changed address(es))",
                category: .coreData
            )
        case .blockedByProtectedConversation:
            Log.debug(
                "Contact-linked addresses applied except to a protected conversation; will retry next cleanup",
                category: .coreData
            )
        case .incomplete:
            Log.warning(
                "Contact-linked addresses could not be applied to conversations; will retry next cleanup",
                category: .coreData
            )
        }
        return true
    }

    /// Runs the adoption pass (`unifyConversationsByContactIfNeeded`) before a
    /// sync run routes its mail, so the mail is stored with what Contacts say
    /// now. Without it the first run after the self set was first adopted
    /// here (an upgrade, a new install, a sign-in to another account) stored
    /// its mail with nothing from Contacts, since the pass in the run's
    /// cleanup comes after the run's mail: mail the user sent from an address
    /// their card adds was stored as someone else's, for good, because nothing
    /// repairs a stored `isFromMe`.
    ///
    /// The same guarantees as the pass in the cleanup: the caller's run owns
    /// the store, and the cleanup-sensitive gate is held here, so nothing
    /// routes or sends between the adoption and the repair. On a context of
    /// its own, never the run's: only the run's save points save that one.
    ///
    /// Announces the end of a cleanup only when it repaired something: in
    /// steady state it is a few comparisons, and the run's own cleanup
    /// announces at its end beside `.syncCompleted`.
    func adoptContactsBeforeRouting(knownAddresses: Set<String>? = nil) async {
        let context = coreDataStack.newBackgroundContext()
        let repaired = await conversationMutationSerializer.performCleanupSensitiveMutation { [self] () async -> Bool in
            let repaired = await unifyConversationsByContactIfNeeded(in: context, knownAddresses: knownAddresses)
            _ = await context.performSaveIfNeeded(caller: "DataCleanupService.adoptContactsBeforeRouting")
            return repaired
        }
        if repaired {
            announceCleanupFinished()
        }
    }

    /// The account's address and its send-as addresses, normalized, read from
    /// the stored `Account` row: what the user's own addresses Contacts add
    /// are decided for. Empty without a row; nil when the read failed, which
    /// is never "none".
    func accountAddresses(in context: NSManagedObjectContext) async -> Set<String>? {
        await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            let rows: [Account]
            do {
                rows = try context.fetch(request)
            } catch {
                Log.error("Failed to read the account's addresses for the self set", category: .coreData, error: error)
                return nil
            }
            guard let account = rows.first else { return [] }
            return Set(([account.email] + account.aliasesArray)
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty })
        }
    }

    /// Which stored conversations a change in the user's own addresses moves.
    struct SelfAddressChange: Equatable {
        /// The addresses whose conversations are given their hash again: every
        /// conversation with a participant row for one of them.
        let changedAddresses: Set<String>
        /// Whether the pass has anything to do for the self set.
        let needsPass: Bool
        /// Whether the current set may be recorded as applied once the pass
        /// completes.
        let isRecordable: Bool

        /// Nothing to do for the self set.
        static let none = SelfAddressChange(changedAddresses: [], needsPass: false, isRecordable: false)

        private init(changedAddresses: Set<String>, needsPass: Bool, isRecordable: Bool) {
            self.changedAddresses = changedAddresses
            self.needsPass = needsPass
            self.isRecordable = isRecordable
        }

        /// - Parameters:
        ///   - applied: The set this account's stored conversations were last
        ///     brought in line with, or nil when none was recorded for it.
        ///   - routedBefore: The set the router hashed with until this pass
        ///     adopted `current`. After a switch of accounts it differs from
        ///     `applied`, and the conversations stored since were hashed with it.
        ///   - current: The adopted set, which the router hashes with now.
        ///   - knownAddresses: The account's address and send-as addresses.
        ///   - legacyOfLastRead: What the rule before the adopted set took as
        ///     the user's, from this process's read; nil when nothing was read.
        ///     Until a set is first recorded, the conversations were hashed
        ///     with that one (or with less, on an install that never ran it),
        ///     so every address either set names is in scope; giving a
        ///     conversation the hash it already has changes nothing. With no
        ///     read and no recorded set there is nothing to record.
        init(
            applied: Set<String>?,
            routedBefore: Set<String>,
            current: Set<String>,
            knownAddresses known: Set<String>,
            legacyOfLastRead: Set<String>?
        ) {
            var changed = routedBefore.symmetricDifference(current)
            var forced = false
            if let applied {
                changed.formUnion(applied.symmetricDifference(current))
                isRecordable = true
            } else if let legacyOfLastRead {
                changed.formUnion(legacyOfLastRead.union(current))
                forced = true
                isRecordable = true
            } else {
                isRecordable = false
            }
            // A note-to-self chat is keyed on the first of the user's addresses
            // in sorted order (`makeParticipantSetIdentity`), and its one row is
            // that address, which need not be one that changed: an address
            // added that sorts first moves the key, and the chat holding the
            // old key names only the old one.
            let keyNow = Self.noteToSelfKey(known: known, contactAddresses: current)
            let earlierKeys = [applied, routedBefore, legacyOfLastRead]
                .compactMap { $0 }
                .compactMap { Self.noteToSelfKey(known: known, contactAddresses: $0) }
            if let keyNow, earlierKeys.contains(where: { $0 != keyNow }) {
                changed.insert(keyNow)
                changed.formUnion(earlierKeys)
            }
            changedAddresses = changed
            needsPass = forced || !changed.isEmpty
        }

        private static func noteToSelfKey(known: Set<String>, contactAddresses: Set<String>) -> String? {
            known.union(contactAddresses).sorted().first
        }
    }
}
