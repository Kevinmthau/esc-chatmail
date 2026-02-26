import XCTest
import CoreData
@testable import esc_chatmail

final class MessageExtensionsTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
    }

    override func tearDown() {
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testConversationPreviewText_forwardedMessage_usesQuotedOriginalSubject() {
        let message = MessageBuilder()
            .withSubject("Fwd: An exceptional chalet in Val d'Isere")
            .withSnippet("Body snippet")
            .build(in: context)

        XCTAssertEqual(message.conversationPreviewText, "fwd: \"An exceptional chalet in Val d'Isere\"")
    }

    func testConversationPreviewText_forwardedMessage_stripsMultipleForwardPrefixes() {
        let message = MessageBuilder()
            .withSubject("FW: Fwd: Weekly update")
            .build(in: context)

        XCTAssertEqual(message.conversationPreviewText, "fwd: \"Weekly update\"")
    }

    func testConversationPreviewText_newsletter_usesSubject() {
        let message = MessageBuilder()
            .asNewsletter()
            .withSubject("Big sale this weekend")
            .withSnippet("Snippet")
            .build(in: context)

        XCTAssertEqual(message.conversationPreviewText, "Big sale this weekend")
    }

    func testConversationPreviewText_regularMessage_prefersCleanedSnippet() {
        let message = MessageBuilder()
            .withSubject("Hello")
            .withSnippet("Raw snippet")
            .build(in: context)
        message.cleanedSnippet = "Clean snippet"

        XCTAssertEqual(message.conversationPreviewText, "Clean snippet")
    }

    func testHTMLDisplayCleanupMode_forwardedMessage_defaultsToNone() {
        let message = MessageBuilder()
            .withSubject("Fwd: Proposal")
            .build(in: context)

        XCTAssertEqual(message.htmlDisplayCleanupMode, .none)
    }

    func testHTMLDisplayCleanupMode_newsletter_defaultsToNone() {
        let message = MessageBuilder()
            .asNewsletter()
            .withSubject("Weekly digest")
            .build(in: context)

        XCTAssertEqual(message.htmlDisplayCleanupMode, .none)
    }

    func testHTMLDisplayCleanupMode_regularMessage_usesQuotedAndSignature() {
        let message = MessageBuilder()
            .withSubject("Re: Plans")
            .build(in: context)

        XCTAssertEqual(message.htmlDisplayCleanupMode, .quotedAndSignature)
    }

    func testHTMLDisplayCleanupMode_sentMessage_defaultsToNone() {
        let message = MessageBuilder()
            .fromMe()
            .withSubject("Re: Plans")
            .build(in: context)

        XCTAssertEqual(message.htmlDisplayCleanupMode, .none)
    }
}
