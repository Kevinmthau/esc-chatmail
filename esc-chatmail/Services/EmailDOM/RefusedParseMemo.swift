import Foundation
import os

/// The refusals `EmailDOMParseAdmission` reaches only by parsing (a body
/// sent to the measuring thread and found too deep there), kept so that the
/// same body is not parsed again only to be refused again. Processing one
/// message asks the gate for its body seven times (text extraction, quote
/// removal, the sanitizer, the snippet and preview passes), and a 193 KB
/// body the measuring thread refused took 1.1 s a parse, 10.4 s for the
/// message, in a Debug build.
///
/// It holds no mail. A body is known by its UTF-8 length, a 64-bit hash of
/// its bytes seeded for this process (`Hasher`, so a sender cannot write a
/// second body that collides with a refused one), and how it is parsed. A
/// refusal is a pure function of those, the same for any account, so the
/// memo is no participant of the account boundary. Only bodies the scan
/// says a parse may refuse are looked up (`EmailDOMParseAdmission`), so
/// ordinary mail is never hashed.
final class RefusedParseMemo: Sendable {
    /// What a body is parsed as: a fragment's tree depends on its context,
    /// which is known by its tag name only where it has no parent and no
    /// document (`EmailDOMParseAdmission.parseFragment` memoizes nothing
    /// else).
    enum ParseKind: Hashable, Sendable {
        case document
        case bodyFragment
        case fragment(context: String)
    }

    struct Key: Hashable, Sendable {
        let length: Int
        let bytesHash: Int
        let kind: ParseKind

        init(_ html: String, kind: ParseKind) {
            var hasher = Hasher()
            let utf8 = html.utf8
            if utf8.withContiguousStorageIfAvailable({ hasher.combine(bytes: UnsafeRawBufferPointer($0)) }) == nil {
                Array(utf8).withUnsafeBytes { hasher.combine(bytes: $0) }
            }
            length = utf8.count
            bytesHash = hasher.finalize()
            self.kind = kind
        }
    }

    static let shared = RefusedParseMemo()

    /// A message's parses come one after another, so a few entries are
    /// enough; more only hold verdicts no one asks for again.
    static let capacity = 64

    private struct State {
        var refusals: [Key: EmailDOMParseRefusal] = [:]
        /// Oldest first, for eviction.
        var order: [Key] = []
        var hits = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The refusal recorded for `key`, if any.
    func refusal(for key: Key) -> EmailDOMParseRefusal? {
        state.withLock { state in
            guard let refusal = state.refusals[key] else { return nil }
            state.hits += 1
            return refusal
        }
    }

    func record(_ refusal: EmailDOMParseRefusal, for key: Key) {
        state.withLock { state in
            if state.refusals.updateValue(refusal, forKey: key) == nil {
                state.order.append(key)
            }
            while state.order.count > Self.capacity {
                state.refusals[state.order.removeFirst()] = nil
            }
        }
    }

    /// How many refusals were answered from the memo, for tests.
    var hitCount: Int {
        state.withLock { $0.hits }
    }
}
