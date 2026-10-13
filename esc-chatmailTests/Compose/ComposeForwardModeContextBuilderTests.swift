import XCTest
@testable import esc_chatmail

@MainActor
final class ComposeForwardModeContextBuilderTests: XCTestCase {
    private func makeTestAuthSession(userEmail: String? = nil) -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ComposeForwardModeContextBuilderTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = userEmail
        return authSession
    }

    func testBuild_formatsForwardContextFromValueInput() {
        let builder = ComposeForwardModeContextBuilder(
            messageFormatBuilder: MessageFormatBuilder(
                authSession: makeTestAuthSession(userEmail: "me@example.com")
            )
        )
        let result = builder.build(
            input: .init(
                source: .init(
                    id: "forward-source-message",
                    subject: "Original Subject",
                    internalDate: Date(timeIntervalSince1970: 1_704_326_400),
                    sender: .init(email: "friend@example.com", displayName: "Friend"),
                    bodyText: "Original message body",
                    snippet: nil,
                    originalHTML: "<html><body><p>Forwarded HTML body</p></body></html>",
                    to: [.init(email: "me@example.com", displayName: "Me")],
                    cc: []
                ),
                forwardedInlineAttachmentInfos: [
                    .init(
                        localURL: "Attachments/forward-inline.png",
                        filename: "inline.png",
                        mimeType: "image/png",
                        contentId: "cid-inline"
                    )
                ],
                forwardedRegularAttachments: [
                    .init(
                        filename: "report.pdf",
                        mimeType: "application/pdf",
                        byteSize: 91_248,
                        localURL: "Attachments/forward-regular.pdf",
                        previewURL: nil,
                        width: 0,
                        height: 0,
                        pageCount: 0
                    )
                ]
            )
        )

        XCTAssertEqual(result.id, "forward-source-message")
        XCTAssertEqual(result.initialSubject, "Fwd: Original Subject")
        XCTAssertTrue(result.forwardedPlainTextBody.contains("---------- Forwarded message ---------"))
        XCTAssertTrue(result.forwardedPlainTextBody.contains("Original message body"))
        XCTAssertTrue(result.forwardedPlainTextBody.contains("From: Friend <friend@example.com>\n"))
        XCTAssertTrue(result.forwardedPlainTextBody.contains("To: Me <me@example.com>\n"))
        XCTAssertTrue(result.forwardedHTMLBody?.contains("Forwarded HTML body") == true)
        XCTAssertEqual(result.forwardedInlineAttachmentInfos.count, 1)
        XCTAssertEqual(result.forwardedInlineAttachmentInfos.first?.contentId, "cid-inline")
        XCTAssertEqual(
            result.forwardedRegularAttachments,
            [
                .init(
                    filename: "report.pdf",
                    mimeType: "application/pdf",
                    byteSize: 91_248,
                    localURL: "Attachments/forward-regular.pdf",
                    previewURL: nil,
                    width: 0,
                    height: 0,
                    pageCount: 0
                )
            ]
        )
    }

    func testBuild_unsafeInlineContentIDFallsBackToPlainForward() {
        let builder = ComposeForwardModeContextBuilder(
            messageFormatBuilder: MessageFormatBuilder(
                authSession: makeTestAuthSession(userEmail: "me@example.com")
            )
        )
        let result = builder.build(
            input: .init(
                source: .init(
                    id: "unsafe-inline-forward",
                    subject: "Original Subject",
                    internalDate: Date(timeIntervalSince1970: 1_704_326_400),
                    sender: nil,
                    bodyText: "Original message body",
                    snippet: nil,
                    originalHTML: "<html><body><img src=\"cid:real%3E%3Cevil@attacker\"></body></html>",
                    to: [],
                    cc: []
                ),
                forwardedInlineAttachmentInfos: [
                    .init(
                        localURL: "Attachments/unsafe-inline.png",
                        filename: "inline.png",
                        mimeType: "image/png",
                        contentId: "real><evil@attacker"
                    )
                ],
                forwardedRegularAttachments: []
            )
        )

        XCTAssertTrue(result.forwardedPlainTextBody.contains("Original message body"))
        XCTAssertNil(result.forwardedHTMLBody)
        XCTAssertTrue(result.forwardedInlineAttachmentInfos.isEmpty)
    }
}
