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

    func testIsDeveloperProgramAgreementNotice_requiresAppleSenderAndNoticeSubject() {
        XCTAssertTrue(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
            senderEmail: "developer@insideapple.apple.com",
            sourceDomain: nil,
            subject: "Updated Apple Developer Program License Agreement Now Available"
        ))
        XCTAssertTrue(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
            senderEmail: "no_reply@email.apple.com",
            sourceDomain: nil,
            subject: "Action Required: Review the updated Paid Applications Agreement"
        ))

        // Subject-anchored on purpose: Apple's developer digests mention
        // agreement updates in the body, and a body-only match would route
        // those newsletters into the transactional card.
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
            senderEmail: "developer@insideapple.apple.com",
            sourceDomain: nil,
            subject: "Hello Developer: October edition"
        ))
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
            senderEmail: "developer@insideapple.apple.com",
            sourceDomain: nil,
            subject: "Apple Developer Program License Agreement"
        ))
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
            senderEmail: "developer@insideapple.apple.com.evil.example",
            sourceDomain: nil,
            subject: "Updated Apple Developer Program License Agreement Now Available"
        ))
    }
}
