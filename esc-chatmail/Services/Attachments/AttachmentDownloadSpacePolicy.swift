import Foundation

/// Whether a received attachment may be downloaded with the free space the volume has, asked
/// before anything is fetched (`AttachmentDownloader.performAttachmentDownload`).
///
/// A download is refused when it would leave less than `floorBytes` free: the same 200 MB below
/// which sync admits no run (`SyncStorageBackoff`) and the launch screen asks for space. Past
/// that point a download helps nobody: new mail has stopped, and the bytes would take the space
/// sync needs to start again. A refused download fetches nothing and writes nothing to the row,
/// which stays `queued`, the resting state of a received attachment, so the next showing asks
/// again once there is room. Until 2026-11-28 nothing was asked: on a full disk each showing
/// downloaded the attachment, failed to write it, marked it failed and, on the next showing,
/// downloaded it again (architecture review 2026-11, attachments-storage-disk#5).
///
/// A reading that could not be made admits the download. Unlike a store reset, which never
/// assumes room it could not measure (`StoreVolumeFreeSpace.hasRoomForStoreReset`), a download
/// destroys nothing, and a write that then finds no room is told apart from other failures
/// (`AttachmentWriteResult.outOfSpace`) and leaves the row as it was.
enum AttachmentDownloadSpacePolicy {
    /// The free space a download must leave.
    static let floorBytes: Int64 = StoreVolumeFreeSpace.lowStorageThresholdBytes

    /// Whether downloading an attachment of `byteSize` bytes (its decoded size, as Gmail stated
    /// it; zero or less when unknown) leaves at least `floorBytes` of `availableBytes`.
    static func admitsDownload(byteSize: Int64, availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return true }
        let needed = max(0, byteSize)
        // Both are non-negative, so the subtraction cannot overflow.
        return availableBytes - needed >= floorBytes
    }
}
