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
    func unifyConversationsByContactIfNeeded(in context: NSManagedObjectContext) async {
        let links = contactLinkStore.refreshIfNeeded()
        let applied = contactLinkStore.appliedToConversations()
        // The steady state, and the whole pass without Contacts access: one
        // comparison, and no conversation read.
        guard links != applied else { return }

        let changedAddresses = links.addressesLinkedDifferently(from: applied)
        let outcome = await fixAndMergeIncorrectParticipantHashes(
            in: context,
            scope: .conversationsNaming(changedAddresses)
        )

        switch outcome {
        case .completed:
            contactLinkStore.markAppliedToConversations(links)
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
}
