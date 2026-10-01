import Foundation
import CoreData

/// The transcript's SwiftUI identity for a row (`ForEach` and `.id`), which —
/// unlike `messageObjectID` — survives sync replacing the user's optimistic
/// reply with Gmail's copy.
///
/// Why: about a second after every reply, sync inserts the echo as a new
/// `Message` (Gmail's ID, a new object ID) and deletes the optimistic row in the
/// same save (`consumeRemoteCommittedSendMutation`). Keyed by object ID, the
/// bubble was torn down and rebuilt: a fresh `MessageBubbleViewModel` with no
/// content, attachment views re-mounted, and the row's height collapsing and
/// regrowing. Both rows carry the same deterministic RFC Message-ID
/// (`MimeBuilder.messageId(forOptimisticMessageID:)` on the optimistic row; the
/// echo stores the `Message-ID` header it was sent with, which is how sync
/// matches it), so keying the user's own sends by the optimistic ID that
/// Message-ID encodes keeps one view across the swap, refreshed in place.
///
/// View identity only. Caches and loaders stay keyed by `message.id` and the
/// object ID under their captured account generations; never key a cache or a
/// `VirtualScrollState` lookup by this. Two rows can briefly share an identity
/// (see `ChatTranscriptIdentityPolicy`), so a collection must go through that
/// policy before it reaches a `ForEach`.
enum ChatMessageDisplayIdentity: Hashable {
    /// A message this app sent: the optimistic message ID decoded from its RFC
    /// Message-ID, shared by the optimistic row and its sync echo.
    case outboundSend(optimisticMessageID: String)
    /// Every other row.
    case message(NSManagedObjectID)

    /// `decodedOutboundSendID` is `MimeBuilder.optimisticMessageID(from:)` of
    /// the row's RFC Message-ID, which the mapper decodes once per row and
    /// shares with its other uses of it.
    ///
    /// `isFromMe` is required: the Message-ID of incoming mail is chosen by
    /// its sender and must not be able to claim the identity of one of the
    /// user's own sends.
    static func resolve(
        isFromMe: Bool,
        decodedOutboundSendID: String?,
        objectID: NSManagedObjectID
    ) -> Self {
        guard isFromMe, let decodedOutboundSendID else {
            return .message(objectID)
        }
        return .outboundSend(optimisticMessageID: decodedOutboundSendID)
    }
}
