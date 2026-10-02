import Foundation

/// What a send-path failure before the transmission barrier does with the
/// durable optimistic graph.
///
/// Nothing reached Gmail in either case, so neither is a duplicate-send
/// hazard; the difference is who owns the user's content afterwards.
/// Account teardown (`closeAdmission` / `cancelAndAwaitAll`) and any
/// pre-barrier cancellation without a recorded cause always roll back,
/// whatever the request asked for: destructive cleanup follows a teardown,
/// and a retained "Not sent" row would be left behind in an account being
/// wiped. Background-time expiry before the barrier is not a teardown and
/// follows the request's disposition: an offline reply parked in
/// `OutboundConnectivityGate` when the phone is locked keeps its "Not sent"
/// bubble rather than vanishing into the draft
/// (`ComposeSendCancellationRelay.teardownRequested`).
enum PreTransmissionFailureDisposition: Equatable, Sendable {
    /// Delete the optimistic graph and hand the body and attachments back to
    /// the source composer, which still owns them until transmission
    /// admission (ComposeView new message and forward).
    case rollBackToComposer
    /// Keep the optimistic row as definitely unsent ("Not sent" with Edit and
    /// resend). The chat reply composer releases its content at optimistic
    /// persistence and may already hold the user's next reply, so a rollback
    /// would bring the bubble's text back into the single per-conversation
    /// draft slot and overwrite (or be overwritten by) that newer draft.
    case retainAsNotSent
}
