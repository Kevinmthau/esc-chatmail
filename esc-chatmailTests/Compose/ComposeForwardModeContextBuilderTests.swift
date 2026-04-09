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
                    isFromMe: false,
                    bodyText: "Original message body",
                    snippet: nil,
                    originalHTML: "<html><body><p>Forwarded HTML body</p></body></html>",
                    participants: [
                        .init(email: "me@example.com", displayName: "Me"),
                        .init(email: "friend@example.com", displayName: "Friend")
                    ]
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
        XCTAssertTrue(result.forwardedPlainTextBody.contains("To: friend@example.com"))
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
}
