import Foundation

// MARK: - Statistics
extension ConversationCache {
    func recordAccessTime(_ time: TimeInterval) {
        accessTimes.append(time)
        if accessTimes.count > 100 {
            accessTimes.removeFirst()
        }
    }

    func getStatistics() -> LRUCacheStatistics {
        return stats
    }

    /// Returns detailed statistics including access time info
    func getDetailedStatistics() -> (stats: LRUCacheStatistics, avgAccessTime: TimeInterval, memoryUsage: Int) {
        let avgAccessTime = accessTimes.isEmpty ? 0 : accessTimes.reduce(0, +) / Double(accessTimes.count)
        return (stats, avgAccessTime, currentMemoryUsage)
    }
}
