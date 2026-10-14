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
        // Revert-check: `AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice`
        // is the gate under test; loosening any of its clauses flips one of the
        // negative cases below.
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
        // A subject that does not name a known agreement still qualifies when
        // the sender identifies the developer program (App Store Connect's
        // display name on its shared no_reply address).
        XCTAssertTrue(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
            senderName: "App Store Connect",
            senderEmail: "no_reply@email.apple.com",
            sourceDomain: nil,
            subject: "Action Required: Updated agreement now available"
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

    func testIsDeveloperProgramAgreementNotice_rejectsDeveloperDigestSubjects() {
        // Apple's real digest subjects carry "agreement(s)" plus "updated" /
        // "now available"; the plural, the "and more" tail and "guidelines" are
        // digest vocabulary, and the digest must keep its newsletter card.
        // Revert-check: dropping the `\bagreement\b` word match or
        // `developerDigestSubjectPatterns` from the gate admits these.
        for subject in [
            "Updated agreements and guidelines now available",
            "Hello Developer: updated agreements, WWDC sessions, and more",
            "Hello Developer: Updated Apple Developer Program License Agreement, WWDC sessions, and more"
        ] {
            XCTAssertFalse(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
                senderName: "Apple Developer",
                senderEmail: "developer@insideapple.apple.com",
                sourceDomain: nil,
                subject: subject
            ), subject)
        }
    }

    func testIsDeveloperProgramAgreementNotice_rejectsNonDeveloperAppleAgreementMail() {
        // Apple Card, Apple Business Manager and iCloud send "agreement
        // updated" notices from apple.com too; without a developer-program term
        // in the subject or sender they were branded "Apple Developer".
        // Revert-check: dropping the `developerProgramTerms` clause admits these.
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
            senderName: "Apple Card",
            senderEmail: "applecard@apple.com",
            sourceDomain: nil,
            subject: "Your Apple Card Customer Agreement has been updated"
        ))
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
            senderName: "Apple Business Manager",
            senderEmail: "noreply@business.apple.com",
            sourceDomain: nil,
            subject: "Updated Apple Business Manager Agreement now available"
        ))
        XCTAssertFalse(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
            senderName: "Jane Doe",
            senderEmail: "jane@apple.com",
            sourceDomain: nil,
            subject: "Please review the updated agreement"
        ))
        // The same subject qualifies once the sender is the developer program.
        XCTAssertTrue(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
            senderName: "Apple Developer",
            senderEmail: "developer@insideapple.apple.com",
            sourceDomain: nil,
            subject: "Please review the updated agreement"
        ))
    }

    func testIsDeveloperProgramAgreementNotice_rejectsRepliesAndForwards() {
        // A developer-support thread about the agreement is a conversation;
        // routing it into the "Apple Developer / Action Required" card hid the
        // human reply.
        // Revert-check: dropping `isReplyOrForwardSubject` from the gate admits these.
        for subject in [
            "Re: Updated Apple Developer Program License Agreement Now Available",
            "RE: Updated Apple Developer Program License Agreement Now Available",
            "Fwd: Updated Apple Developer Program License Agreement Now Available",
            "FW: Updated Paid Applications Agreement now available"
        ] {
            XCTAssertFalse(AppStoreNotificationPreviewExtractor.isDeveloperProgramAgreementNotice(
                senderName: "Developer Programs",
                senderEmail: "devprograms@apple.com",
                sourceDomain: nil,
                subject: subject
            ), subject)
        }
    }
}
