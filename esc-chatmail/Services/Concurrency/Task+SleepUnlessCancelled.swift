import Foundation

extension Task where Success == Never, Failure == Never {
    /// Sleeps for `nanoseconds` and reports whether the full delay elapsed.
    /// Returns `false` without delay if the task is cancelled — including when
    /// it was already cancelled on entry.
    ///
    /// This replaces the `try? await Task.sleep(...)` pattern, which silently
    /// swallows `CancellationError`: a cancelled task sails through the "delay"
    /// instantly, so backoff loops hammer their remaining retries with zero
    /// delay and debounced work runs despite cancellation. The result is
    /// non-discardable so callers must decide what cancellation means:
    ///
    ///     guard await Task.sleepUnlessCancelled(nanoseconds: delay) else { return }
    ///
    /// Not for timeout racers (`AsyncTimeout`, the remote-image data-URL races
    /// in `HTMLRemoteImageAttachmentFallback`): those deliberately treat an
    /// early-returning sleep as "race settled" and must not bail out.
    static func sleepUnlessCancelled(nanoseconds: UInt64) async -> Bool {
        // Task.sleep(nanoseconds:) only throws CancellationError.
        (try? await Task.sleep(nanoseconds: nanoseconds)) != nil
    }
}
