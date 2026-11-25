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
    func unifyConversationsByContactIfNeeded(in context: NSManagedObjectContext) async {
        let known = await accountAddresses(in: context)
        let links = contactLinkStore.refreshIfNeeded(knownAddresses: known)
        let applied = contactLinkStore.appliedToConversations()
        let selfAddresses = contactLinkStore.selfAddressesSnapshot(forKnown: known)
        let selfChange = SelfAddressChange(
            applied: contactLinkStore.appliedSelfAddresses(),
            current: selfAddresses,
            legacyOfLastRead: contactLinkStore.legacySelfAddressesOfLastRead()
        )
        // The steady state, and the whole pass without Contacts access: a few
        // comparisons, and no conversation read.
        guard links != applied || selfChange.needsPass else { return }

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
                contactLinkStore.markSelfAddressesApplied(selfAddresses)
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
    }

    /// The account's address and its send-as addresses, normalized, read from
    /// the stored `Account` row: what the user's own addresses Contacts add
    /// are decided for. Empty without a row, which leaves that set as it is.
    func accountAddresses(in context: NSManagedObjectContext) async -> Set<String> {
        await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            guard let account = try? context.fetch(request).first else { return [] }
            return Set(([account.email] + account.aliasesArray)
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty })
        }
    }

    /// Which stored conversations a change in the user's own addresses moves.
    struct SelfAddressChange: Equatable {
        /// The addresses that came into or left the set: every conversation
        /// with a participant row for one of them is given its hash again.
        let changedAddresses: Set<String>
        /// Whether the pass has anything to do for the self set.
        let needsPass: Bool
        /// Whether the current set may be recorded as applied once the pass
        /// completes.
        let isRecordable: Bool

        /// - Parameters:
        ///   - applied: The set the stored conversations were last brought
        ///     in line with, or nil when none was ever recorded.
        ///   - current: The adopted set, which the router hashes with now.
        ///   - legacyOfLastRead: What the rule before the adopted set took as
        ///     the user's, from this process's read; nil when nothing was read.
        ///     Until a set is first recorded, the conversations were hashed
        ///     with that one (or with less, on an install that never ran it),
        ///     so every address either set names is in scope; giving a
        ///     conversation the hash it already has changes nothing. With no
        ///     read there is nothing to compare with: the pass waits.
        init(applied: Set<String>?, current: Set<String>, legacyOfLastRead: Set<String>?) {
            if let applied {
                changedAddresses = applied.symmetricDifference(current)
                needsPass = !changedAddresses.isEmpty
                isRecordable = true
            } else if let legacyOfLastRead {
                changedAddresses = legacyOfLastRead.union(current)
                needsPass = true
                isRecordable = true
            } else {
                changedAddresses = []
                needsPass = false
                isRecordable = false
            }
        }
    }
}
