import Foundation

/// Free space on the volume that holds the mailbox store, as SQLite can use
/// it. The launch screen's full-disk notice and the store reset's refusal both
/// read it, so the screen never offers a reset the stack would refuse.
///
/// `volumeAvailableCapacityForImportantUsage` alone overstates that space: it
/// counts purgeable files the system has not purged yet, and SQLite cannot
/// write into those, so a device reporting gigabytes there can still fail
/// every open with SQLITE_CANTOPEN. The reading is the smaller of that figure
/// and the volume's actual free capacity.
enum StoreVolumeFreeSpace {
    /// Below this much free space an open failure is treated as a full disk:
    /// the launch screen asks for space instead of offering a reset, and the
    /// stack refuses to reset. At 0 bytes free SQLite reports SQLITE_CANTOPEN
    /// rather than SQLITE_FULL, so the error alone cannot tell.
    static let lowStorageThresholdBytes: Int64 = 200 * 1024 * 1024

    /// Bytes free on the volume holding the app's container, or nil when the
    /// volume could not be read.
    static func availableBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return usableBytes(
            availableCapacity: values?.volumeAvailableCapacity.map(Int64.init),
            importantUsageCapacity: values?.volumeAvailableCapacityForImportantUsage
        )
    }

    /// The smaller of the two readings, either alone when only one could be
    /// read, or nil when neither could.
    static func usableBytes(availableCapacity: Int64?, importantUsageCapacity: Int64?) -> Int64? {
        switch (availableCapacity, importantUsageCapacity) {
        case let (available?, importantUsage?):
            return min(available, importantUsage)
        case let (available?, nil):
            return available
        case let (nil, importantUsage?):
            return importantUsage
        case (nil, nil):
            return nil
        }
    }

    /// True only when a reading shows at least `lowStorageThresholdBytes`. A
    /// reset never assumes room it could not measure: on a full disk it
    /// frees nothing (the backup is a clone that keeps every block) and
    /// destroys data that freeing space would have kept.
    static func hasRoomForStoreReset(availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return false }
        return availableBytes >= lowStorageThresholdBytes
    }
}
