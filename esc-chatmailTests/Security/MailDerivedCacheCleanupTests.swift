import XCTest
@testable import esc_chatmail
#if os(iOS)
import UIKit
#endif

/// What a sign-out removes of the mailbox outside the store, the message bodies and the
/// attachment folders (`AuthSession.clearMailDerivedCaches`), and that the two cleanups that
/// owe it still call it.
///
/// Every `AuthSession` a test builds injects its own `deleteAttachmentFiles`, and every
/// `FreshInstallHandler` its own cleanup, so no other suite runs this function or notices
/// that a call to it has gone. A sign-out would then again leave correspondents' photos,
/// the images downloaded for mail, the cached responses and the web views' data.
///
/// HONEST SCOPE: one test here runs the function, on iOS alone, and asks only for the avatar
/// files and the image cache. It acts on the shared stores of the test host, which on the
/// iOS simulator are the test host's own; in the Mac test host they are the container of the
/// Mac app in daily use, so that test is not compiled there and this suite is not in
/// `Mac.xctestplan`. That the function is called, and that it empties the URL cache and the
/// web views' store, is read from source. Nothing has been seen in the app.
final class MailDerivedCacheCleanupTests: XCTestCase {
    #if os(iOS)
    /// Revert-check: deleting `await AvatarStorage.shared.deleteAllAvatars()` from
    /// `AuthSession.clearMailDerivedCaches` makes the avatar assertion fail, and deleting
    /// `await EnhancedImageCache.shared.clearAll()` makes the image one fail.
    func testClearMailDerivedCaches_storedAvatarAndCachedImage_areRemoved() async throws {
        let email = "cleanup-\(UUID().uuidString)@example.com"
        let imageKey = "https://example.com/\(UUID().uuidString).png"
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let savedAvatar = await AvatarStorage.shared.saveAvatar(
            for: email,
            imageData: try XCTUnwrap(image.pngData())
        )
        await EnhancedImageCache.shared.set(image, for: imageKey)
        // The image is read back from its file, not from memory, before the cleanup.
        await EnhancedImageCache.shared.clearMemory()
        let avatarWasStored = await AvatarStorage.shared.avatarExists(for: email)
        let imageWasCached = await EnhancedImageCache.shared.get(for: imageKey) != nil
        XCTAssertNotNil(savedAvatar)
        XCTAssertTrue(avatarWasStored, "Precondition: the avatar's file is there")
        XCTAssertTrue(imageWasCached, "Precondition: the image is in the cache")

        await AuthSession.clearMailDerivedCaches()

        let avatarIsStored = await AvatarStorage.shared.avatarExists(for: email)
        let imageIsCached = await EnhancedImageCache.shared.get(for: imageKey) != nil
        XCTAssertFalse(avatarIsStored, "A sign-out left a correspondent's photo")
        XCTAssertFalse(imageIsCached, "A sign-out left an image downloaded for mail")
    }
    #endif

    /// Revert-check: deleting `URLCache.shared.removeAllCachedResponses()` or
    /// `await clearWebViewData()` from `AuthSession.clearMailDerivedCaches` makes this fail.
    /// HONEST SCOPE: source text. The two that the test above runs are listed too, so that
    /// the Mac, where it is not compiled, is not left with nothing.
    func testClearMailDerivedCaches_removesEachOfTheFourCaches() throws {
        let code = try codeLines("esc-chatmail/Services/Security/AuthSession.swift")
        let function = try XCTUnwrap(code.firstIndex(of: "nonisolated static func clearMailDerivedCaches() async {"))
        let nextFunction = try XCTUnwrap(code[(function + 1)...].firstIndex { $0.contains("func ") })
        let body = Array(code[(function + 1)..<nextFunction])

        for removal in [
            "await AvatarStorage.shared.deleteAllAvatars()",
            "await EnhancedImageCache.shared.clearAll()",
            "URLCache.shared.removeAllCachedResponses()",
            "await clearWebViewData()"
        ] {
            XCTAssertTrue(body.contains(removal), "clearMailDerivedCaches no longer runs `\(removal)`")
        }
    }

    /// The account-removal cleanup reaches the function through `AuthSession`'s default
    /// `deleteAttachmentFiles`, after the deletion that can throw: on the Mac that one's
    /// tripwire refusal must fail the cleanup before anything else is removed.
    ///
    /// Revert-check: deleting `await AuthSession.clearMailDerivedCaches()` from the default
    /// `deleteAttachmentFiles` closure of `AuthSession.init`, or moving it above
    /// `try AuthSession.deleteAttachmentFilesFromDisk()`, makes this fail.
    func testAccountRemoval_defaultFileCleanup_clearsTheMailDerivedCachesAfterTheAttachmentFiles() throws {
        let code = try codeLines("esc-chatmail/Services/Security/AuthSession.swift")
        let closure = try XCTUnwrap(code.firstIndex(
            of: "deleteAttachmentFiles: @escaping @Sendable () async throws -> Void = {"
        ))

        XCTAssertEqual(Array(code[(closure + 1)...(closure + 3)]), [
            "try AuthSession.deleteAttachmentFilesFromDisk()",
            "await AuthSession.clearMailDerivedCaches()",
            "},"
        ])
    }

    /// Revert-check: deleting `await AuthSession.clearMailDerivedCaches()` from
    /// `FreshInstallHandler.performCleanup` makes this fail.
    func testFreshInstallCleanup_clearsTheMailDerivedCaches() throws {
        let code = try codeLines("esc-chatmail/App/FreshInstallHandler.swift")
        let function = try XCTUnwrap(code.firstIndex(of: "private func performCleanup() async {"))
        let nextFunction = try XCTUnwrap(code[(function + 1)...].firstIndex { $0.contains("func ") })
        let body = Array(code[(function + 1)..<nextFunction])
        let attachmentFiles = try XCTUnwrap(body.firstIndex(of: "clearAttachmentFiles()"))

        XCTAssertEqual(body[attachmentFiles + 1], "await AuthSession.clearMailDerivedCaches()")
    }

    /// The file's lines, trimmed, without its comment lines.
    private func codeLines(_ path: String) throws -> [String] {
        try repositorySource(path)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }
}
