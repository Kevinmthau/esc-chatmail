import XCTest
@testable import esc_chatmail

final class AppStoreNotificationSenderTests: XCTestCase {
    func testIsAppleDeveloperSender_acceptsAppleSubdomainSenders() {
        XCTAssertTrue(AppStoreNotificationPreviewExtractor.isAppleDeveloperSender(
            senderEmail: "no_reply@email.apple.com",
            sourceDomain: nil
        ))
        XCTAssertTrue(AppStoreNotificationPreviewExtractor.isAppleDeveloperSender(
            senderEmail: "no_reply@appstoreconnect.apple.com",
            sourceDomain: nil
        ))
        XCTAssertTrue(AppStoreNotificationPreviewExtractor.isAppleDeveloperSender(
            senderEmail: "App Store Connect <no_reply@email.apple.com>",
            sourceDomain: nil
        ))
        XCTAssertTrue(AppStoreNotificationPreviewExtractor.isAppleDeveloperSender(
            senderEmail: nil,
            sourceDomain: "email.apple.com"
        ))
    }

    func testIsAppleDeveloperSender_rejectsSpoofedSenders() {
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isAppleDeveloperSender(
            senderEmail: "no_reply@email.apple.com.evil.example",
            sourceDomain: nil
        ))
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isAppleDeveloperSender(
            senderEmail: "\"no_reply@email.apple.com\" <attacker@evil.example>",
            sourceDomain: nil
        ))
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isAppleDeveloperSender(
            senderEmail: "attacker@notapple.com",
            sourceDomain: nil
        ))
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isAppleDeveloperSender(
            senderEmail: nil,
            sourceDomain: "apple.com.evil.example"
        ))
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isAppleDeveloperSender(
            senderEmail: nil,
            sourceDomain: nil
        ))
    }
}
