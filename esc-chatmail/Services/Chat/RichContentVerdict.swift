import Foundation

/// Whether a message's stored content is genuine rich HTML (a preview card) rather than text,
/// as `RichContentVerdictResolver` decides it and `Message.richContentVerdict` persists it, so
/// a chat bubble knows at mount what its async content load will conclude.
enum RichContentVerdict: Sendable, Equatable {
    /// No verdict under the current epoch: the row was never stamped, was stamped by older
    /// classifier code, or its stored state could not be read when it was last evaluated.
    case unknown
    case notRich
    case rich

    init(isRich: Bool) {
        self = isRich ? .rich : .notRich
    }

    /// nil for `.unknown`.
    var isRich: Bool? {
        switch self {
        case .unknown:
            return nil
        case .notRich:
            return false
        case .rich:
            return true
        }
    }

    /// Decodes `Message.richContentVerdict`. A value stamped under any other epoch, and a
    /// value no epoch produces, reads as `.unknown`.
    init(storedValue: Int16, epoch: Int16 = CacheVersioning.richContentVerdictEpoch) {
        guard epoch >= 1, storedValue >= 2, storedValue / 2 == epoch else {
            self = .unknown
            return
        }
        self = storedValue % 2 == 1 ? .rich : .notRich
    }

    /// The persisted encoding: 0 for unknown, otherwise `epoch * 2 + (rich ? 1 : 0)`.
    ///
    /// The epoch is part of the value so a verdict stamped by older classifier code reads as
    /// unknown the moment `CacheVersioning.richContentVerdictEpoch` is bumped. Versioning only
    /// the backfill would leave every not-yet-rescanned row holding the old code's answer as a
    /// known one: the bubble would render it at mount and its load would then contradict it,
    /// which is the swap a known verdict exists to remove. An unknown row shows the loading
    /// pill instead, as every row did before verdicts were stored.
    func storedValue(epoch: Int16 = CacheVersioning.richContentVerdictEpoch) -> Int16 {
        switch self {
        case .unknown:
            return 0
        case .notRich:
            return epoch * 2
        case .rich:
            return epoch * 2 + 1
        }
    }
}
