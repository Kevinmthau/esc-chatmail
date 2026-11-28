import Foundation

/// Which merged Person changes can alter a row of the conversation list's window.
///
/// Every merged save that touches a Person registered in the observed context reports it
/// as updated or refreshed: a contact's name or photo written by Contacts, a better From
/// header name, and also the inverse-only change of a new message naming the person (the
/// send path pins the user's recipients in the view context, and every later merged save
/// that adds a message to or from them reports them). The list used to walk each such
/// Person's `conversationParticipations` and snapshot every conversation the person ever
/// joined, archived ones included, on the main thread (architecture review 2026-11,
/// gap-change-propagation-pipeline#1, contacts-person#6). Most of those reports change
/// nothing a row shows, so this answers first, from the window's own snapshots, whether a
/// fetch is needed at all.
///
/// A row's snapshot reads a Person's address and display name and nothing else
/// (`ConversationSnapshot.participantDisplayNames`, from which its address list and
/// fingerprint are made too); the list's filters read the address alone, and search reads
/// only the conversation. So a Person can change a window row only where some row shows
/// its address with another name. A Person whose address no row shows is in no window
/// row whose snapshot reads it: every participant with an address is in its row's pairs,
/// except in a list conversation's row, which shows no participant and keeps no pairs,
/// so no Person change can alter it; a participant
/// newly given to a row changes the conversation's own `participants` and reaches the list
/// as a changed Conversation, and one the duplicate-Person merge re-points to another
/// Person keeps its address, which the row shows. Rows sharing an address with a
/// duplicate Person (duplicates exist by design) are covered: the check asks whether
/// every name the window shows for the address is this Person's, not whether one is. This
/// rests on no Person writer changing an address beyond its normalization, which the
/// snapshot applies too.
enum ConversationListPersonChangePolicy {
    /// The names the window's rows show for each of `emails` (normalized), from each row's
    /// `ConversationSnapshot.participantDisplayNames`. An address no row shows has no entry.
    static func shownDisplayNamesByEmail(
        in rows: [[ConversationSnapshot.ParticipantDisplayName]],
        forEmails emails: Set<String>
    ) -> [String: Set<String>] {
        guard !emails.isEmpty else { return [:] }
        var result: [String: Set<String>] = [:]
        for row in rows {
            for entry in row where emails.contains(entry.email) {
                result[entry.email, default: []].insert(entry.displayName)
            }
        }
        return result
    }

    /// Whether a Person whose current address is `normalizedEmail` and whose current name
    /// is `displayName` can change the snapshot of a window row, given the names the window
    /// shows (`shownDisplayNamesByEmail`). False for a person with no address (a snapshot
    /// leaves such a participant out), for an address no row shows, and where every row
    /// showing the address already shows this name.
    static func mayChangeWindowRows(
        normalizedEmail: String,
        displayName: String?,
        shownDisplayNamesByEmail: [String: Set<String>]
    ) -> Bool {
        guard !normalizedEmail.isEmpty,
              let shownNames = shownDisplayNamesByEmail[normalizedEmail],
              !shownNames.isEmpty else {
            return false
        }
        return shownNames != [displayName ?? ""]
    }
}
