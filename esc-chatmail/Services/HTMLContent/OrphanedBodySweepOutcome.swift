import Foundation

/// How a sweep of `Messages` for bodies no stored row names ended
/// (`HTMLContentHandler.cleanupOrphanedFiles`). Only `completed` is a sweep that did its
/// whole job; the daily cleanup reports anything else as not done.
enum OrphanedBodySweepOutcome: Equatable, Sendable {
    /// Every file was asked about, and the ones no row names, and not written since the
    /// sweep began, are gone.
    case completed
    /// Stopped between two chunks because its task was cancelled: a background task's
    /// expiration, or an account transition's quiescence.
    case cancelled
    /// A chunk's store question threw. That chunk and every later one removed nothing: a
    /// failed read is never "no rows".
    case storeUnreadable
    /// The boundary was closed, or reopened for another account, after the caller captured
    /// its generation (or the caller had none): nothing from then on was this sweep's.
    case accountChanged
    /// Refused before it began, outside the App Sandbox on the Mac (`SandboxTripwire`).
    case refused
}
