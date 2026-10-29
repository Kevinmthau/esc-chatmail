import Foundation

/// Counts full-format `getMessage` calls per message ID, for tests that
/// script a different outcome on a redundant second fetch.
actor FullFetchCounter {
    private var counts: [String: Int] = [:]

    /// Records one fetch of `id` and returns how many it has had so far.
    func increment(_ id: String) -> Int {
        counts[id, default: 0] += 1
        return counts[id, default: 0]
    }

    func count(for id: String) -> Int {
        counts[id, default: 0]
    }
}
