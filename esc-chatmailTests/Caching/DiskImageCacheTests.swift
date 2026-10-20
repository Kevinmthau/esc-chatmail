import XCTest
@testable import esc_chatmail

final class DiskImageCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskImageCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    /// Two URLs that agree on their first 48 bytes (one CDN path, two pictures)
    /// keep separate entries.
    ///
    /// Revert-check: fails if `DiskImageCache.cacheFilename(for:)` goes back to
    /// the URL's base64 cut to 64 characters — both URLs then map to one file,
    /// the second save overwrites the first, and the first URL reads back the
    /// second picture's bytes.
    func testGetData_urlsSharingAFortyEightBytePrefix_returnTheirOwnBytes() async {
        let cache = DiskImageCache(cacheDirectory: directory, startsPeriodicCleanup: false)
        let storyA = "https://cdn.example.com/newsletters/2026/10/images/story-a.jpg"
        let storyB = "https://cdn.example.com/newsletters/2026/10/images/story-b.jpg"
        XCTAssertEqual(
            Array(storyA.utf8.prefix(48)),
            Array(storyB.utf8.prefix(48)),
            "fixture must share the 48-byte prefix the legacy name truncated to"
        )
        let bytesA = Data("story-a".utf8)
        let bytesB = Data("story-b".utf8)

        await cache.save(bytesA, for: storyA)
        await cache.save(bytesB, for: storyB)

        let readA = await cache.getData(for: storyA)
        let readB = await cache.getData(for: storyB)
        XCTAssertEqual(readA, bytesA)
        XCTAssertEqual(readB, bytesB)
    }

    /// The filename is a digest of the whole URL and the same in every process,
    /// so an entry written before a relaunch is found after it.
    ///
    /// Revert-check: fails if `cacheFilename(for:)` stops hashing the full URL
    /// with SHA-256 — a truncated or per-process-seeded name changes the pinned
    /// value.
    func testCacheFilename_anyURL_isTheSHA256DigestOfTheWholeURL() {
        let url = "https://cdn.example.com/newsletters/2026/10/images/story-a.jpg"

        let filename = DiskImageCache.cacheFilename(for: url)

        XCTAssertEqual(
            filename,
            "f45caa4e5da2f3b02eac43143e050ef396dcf07112a0aa722a416bdb12ae8974.cache"
        )
        XCTAssertTrue(DiskImageCache.isCurrentCacheFilename(filename))
        XCTAssertFalse(DiskImageCache.isCurrentCacheFilename(legacyFilename(for: url)))
    }

    /// A file named by the retired scheme is swept on the next cleanup pass
    /// whatever its age, while a current entry survives.
    ///
    /// Revert-check: fails if `performCleanup` stops routing non-current
    /// filenames to deletion — the legacy file is fresh, so the age and size
    /// rules alone keep it.
    func testPerformCleanup_legacyBase64NamedEntryPresent_removesItAndKeepsCurrentOnes() async throws {
        let cache = DiskImageCache(cacheDirectory: directory, startsPeriodicCleanup: false)
        let url = "https://cdn.example.com/newsletters/2026/10/images/story-a.jpg"
        let bytes = Data("story-a".utf8)
        await cache.save(bytes, for: url)
        let legacyFile = directory.appendingPathComponent(legacyFilename(for: url))
        try Data("legacy".utf8).write(to: legacyFile)

        await cache.performCleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        let current = await cache.getData(for: url)
        XCTAssertEqual(current, bytes)
    }

    /// Opting into the periodic sweep runs its first pass at once, with no
    /// explicit `performCleanup()` call; `shared` relies on this to bound
    /// `Caches/ImageCache` across relaunches. The sweep's task retains the
    /// instance for the rest of the process, which is why the other tests opt
    /// out.
    ///
    /// Revert-check: fails if `init` stops starting `cleanupTask` when
    /// `startsPeriodicCleanup` is true, or starts it without `runImmediately`.
    ///
    /// HONEST SCOPE: this pins the flag's wiring on an injected directory, not
    /// that `shared` passes `true`. That literal is documented at its
    /// declaration; the shared instance sweeps the real cache directory, so no
    /// test constructs it.
    func testInit_startsPeriodicCleanupTrue_sweepsTheDirectoryWithoutAnExplicitCall() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyFile = directory.appendingPathComponent(
            legacyFilename(for: "https://cdn.example.com/newsletters/2026/10/images/story-a.jpg")
        )
        try Data("legacy".utf8).write(to: legacyFile)

        _ = DiskImageCache(cacheDirectory: directory, startsPeriodicCleanup: true)

        await waitUntil { !FileManager.default.fileExists(atPath: legacyFile.path) }
    }

    /// The name the retired scheme produced: the URL's base64, filesystem-safe,
    /// cut to 64 characters.
    private func legacyFilename(for url: String) -> String {
        let stem = Data(url.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .prefix(64)
        return "\(stem).cache"
    }

    /// Copied shape from ContactsAuthorizationCoordinatorTests, minus the
    /// main-actor condition: this suite polls the filesystem. The sweep lands
    /// within milliseconds; the deadline is a generous bound, not a pace.
    /// The condition is checked before the deadline on every pass, so a stall
    /// longer than the timeout cannot fail a condition that came true during
    /// the stall.
    private func waitUntil(
        timeout: TimeInterval = 10.0,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        condition: @escaping @Sendable () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
