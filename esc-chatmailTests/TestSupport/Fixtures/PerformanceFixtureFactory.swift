import Foundation
import CoreData
@testable import esc_chatmail

enum PerformanceFixtureFactory {
    static let currentUserEmail = "me@example.com"
    private static let onePixelPNGDataURL =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII="
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    struct SeededThread {
        let conversation: Conversation
        let messages: [Message]
        let htmlMessageIDs: [String]
    }

    @discardableResult
    static func seedConversationList(
        in context: NSManagedObjectContext,
        conversationCount: Int = 360,
        nonMeParticipantsPerConversation: Int = 3
    ) throws -> [Conversation] {
        var conversations: [Conversation] = []

        for index in 0..<conversationCount {
            let builder = ConversationBuilder()
                .withKeyHash("perf-conversation-\(index)")
                .withParticipantHash("perf-participants-\(index)")
                .withDisplayName(displayName(forConversationAt: index))
                .withSnippet(snippet(forConversationAt: index))
                .withLastMessageDate(baseDate.addingTimeInterval(TimeInterval(-index * 180)))
                .withUnreadCount(index.isMultiple(of: 6) ? 2 : 0)
                .visible()

            if index.isMultiple(of: 11) {
                _ = builder.asNewsletter()
            }

            if index.isMultiple(of: 29) {
                _ = builder.setPinned()
            }

            let conversation = builder.build(in: context)
            addConversationParticipants(
                to: conversation,
                in: context,
                nonMeParticipantsPerConversation: nonMeParticipantsPerConversation,
                seed: index
            )
            conversations.append(conversation)
        }

        try context.save()
        return conversations
    }

    @discardableResult
    static func seedLongThread(
        in context: NSManagedObjectContext,
        htmlContentHandler: HTMLContentHandler,
        messageCount: Int = 420
    ) throws -> SeededThread {
        let conversation = ConversationBuilder()
            .withKeyHash("perf-thread-conversation")
            .withParticipantHash("perf-thread-participants")
            .withDisplayName("Performance Thread")
            .withSnippet("Latest thread snippet")
            .withLastMessageDate(baseDate.addingTimeInterval(TimeInterval(messageCount * 75)))
            .visible()
            .build(in: context)

        let senders = [
            (email: currentUserEmail, name: "Me", isFromMe: true),
            (email: "alex@example.com", name: "Alex", isFromMe: false),
            (email: "jordan@example.com", name: "Jordan", isFromMe: false),
            (email: "ops@example.com", name: "Ops", isFromMe: false)
        ]

        addConversationParticipants(
            to: conversation,
            in: context,
            participants: senders.map { ($0.email, $0.name) }
        )

        var messages: [Message] = []
        var htmlMessageIDs: [String] = []

        for index in 0..<messageCount {
            let sender = senders[index % senders.count]
            let messageID = "perf-thread-message-\(index)"
            let builder = MessageBuilder()
                .withId(messageID)
                .withThreadId("perf-thread")
                .withSubject(index.isMultiple(of: 9) ? "Quarterly launch update \(index / 9)" : "Re: Performance Thread")
                .withSender(email: sender.email, name: sender.name)
                .withSnippet("Message \(index) snippet for scroll and load benchmarking.")
                .withBody(index.isMultiple(of: 8) ? plainTextFallbackBody(paragraphCount: 10) : bodyText(forThreadMessageAt: index))
                .withDate(baseDate.addingTimeInterval(TimeInterval(index * 75)))
                .inConversation(conversation)

            if sender.isFromMe {
                _ = builder.fromMe()
            }

            if index.isMultiple(of: 14) {
                _ = builder.asNewsletter()
            }

            let message = builder.build(in: context)

            if index.isMultiple(of: 5) {
                let html = index.isMultiple(of: 15)
                    ? largeNewsletterHTML(sectionCount: 18, repeatedParagraphCount: 4)
                    : mediumHTMLMessage(token: "thread-\(index)")
                _ = htmlContentHandler.saveHTML(html, for: messageID)
                htmlMessageIDs.append(messageID)
            }

            messages.append(message)
        }

        conversation.lastMessageDate = messages.last?.internalDate
        conversation.snippet = messages.last?.snippet
        try context.save()

        return SeededThread(
            conversation: conversation,
            messages: messages,
            htmlMessageIDs: htmlMessageIDs
        )
    }

    static func mediumHTMLMessage(token: String = "medium") -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>Project Update \(token)</title>
          <style>
            body { margin: 0; padding: 24px; font-family: -apple-system, BlinkMacSystemFont, sans-serif; color: #1f2933; }
            .card { max-width: 640px; margin: 0 auto; border: 1px solid #d8dee9; border-radius: 16px; overflow: hidden; }
            .header { padding: 24px; background: #f5f7fa; }
            .content { padding: 24px; }
            .summary { font-size: 17px; line-height: 1.5; }
            .details { margin-top: 20px; }
            .details li { margin-bottom: 10px; }
          </style>
        </head>
        <body>
          <div class="card">
            <div class="header">
              <h1>Project Update \(token)</h1>
              <p>Status snapshot for the next release candidate.</p>
            </div>
            <div class="content">
              <p class="summary">
                We completed the rendering cleanup, tightened background sync state handling, and are
                monitoring a few regressions around first paint latency for heavier HTML email bodies.
              </p>
              <ul class="details">
                <li>First-paint fallback now preserves readable content when remote images fail.</li>
                <li>Inbox rows remain responsive with mixed newsletter and one-to-one threads.</li>
                <li>Next step is validating memory behavior under repeated HTML opens.</li>
              </ul>
              <p>
                Review the full notes in the attached thread summary and keep an eye on layout stability
                for long-form HTML senders.
              </p>
            </div>
          </div>
        </body>
        </html>
        """
    }

    static func largeNewsletterHTML(
        sectionCount: Int = 42,
        repeatedParagraphCount: Int = 5
    ) -> String {
        let sections = (0..<sectionCount).map { index in
            let paragraphs = (0..<repeatedParagraphCount).map { paragraphIndex in
                """
                <p>
                  Section \(index) paragraph \(paragraphIndex) covers a realistic mix of promotional copy,
                  product detail, event timing, policy links, and footer-heavy newsletter prose intended to
                  stress sanitization, wrapping, and preview extraction without requiring network access.
                </p>
                """
            }
            .joined(separator: "\n")

            return """
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin-bottom: 24px;">
              <tr>
                <td style="padding: 18px; border: 1px solid #e5e7eb; background: #ffffff;">
                  <img src="\(onePixelPNGDataURL)" width="640" height="220" alt="Hero \(index)" style="display:block;width:100%;height:auto;margin-bottom:16px;">
                  <h2 style="margin:0 0 12px 0;">Feature Story \(index)</h2>
                  \(paragraphs)
                  <p><a href="https://example.com/offer/\(index)">Explore this section</a></p>
                </td>
              </tr>
            </table>
            """
        }
        .joined(separator: "\n")

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>Weekly Product Dispatch</title>
          <style>
            body { margin: 0; padding: 0; background: #f3f4f6; }
            table { border-collapse: collapse; }
            .shell { width: 100%; background: #f3f4f6; }
            .content { max-width: 680px; margin: 0 auto; }
            .footer { color: #6b7280; font-size: 13px; line-height: 1.5; }
          </style>
        </head>
        <body>
          <table role="presentation" class="shell" width="100%" cellpadding="0" cellspacing="0">
            <tr>
              <td align="center">
                <table role="presentation" class="content" width="100%" cellpadding="0" cellspacing="0">
                  <tr>
                    <td style="padding: 24px;">
                      <p>View in browser</p>
                      <h1 style="margin: 0 0 20px 0;">Weekly Product Dispatch</h1>
                      <p>
                        A long-form newsletter fixture used to benchmark preview derivation, sanitization, and
                        full-message rendering on large HTML documents.
                      </p>
                      \(sections)
                      <div class="footer">
                        <p>Manage preferences</p>
                        <p>Privacy policy</p>
                        <p>Unsubscribe</p>
                      </div>
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        </body>
        </html>
        """
    }

    static func plainTextFallbackBody(paragraphCount: Int = 80) -> String {
        let paragraphs = (0..<paragraphCount).map { index in
            """
            Line \(index): This fallback body represents a long plain-text email with status detail, explicit
            wrapping, and enough content to exercise quote handling and HTML conversion without depending on HTML input.
            """
        }

        return paragraphs.joined(separator: "\n\n")
    }

    static func cleanupHTMLArtifacts(
        for messageIDs: [String],
        using contentHandler: HTMLContentHandler
    ) {
        for messageID in messageIDs {
            contentHandler.deleteHTML(for: messageID)
        }
    }

    private static func addConversationParticipants(
        to conversation: Conversation,
        in context: NSManagedObjectContext,
        nonMeParticipantsPerConversation: Int,
        seed: Int
    ) {
        var participants: [(String, String)] = [(currentUserEmail, "Me")]

        for offset in 0..<nonMeParticipantsPerConversation {
            let email = "participant-\(seed)-\(offset)@example.com"
            let name = "Participant \(seed)-\(offset)"
            participants.append((email, name))
        }

        addConversationParticipants(to: conversation, in: context, participants: participants)
    }

    private static func addConversationParticipants(
        to conversation: Conversation,
        in context: NSManagedObjectContext,
        participants: [(email: String, name: String)]
    ) {
        for participant in participants {
            let person = PersonBuilder()
                .withEmail(participant.email)
                .withDisplayName(participant.name)
                .build(in: context)

            let conversationParticipant = ConversationParticipant(context: context)
            conversationParticipant.id = UUID()
            conversationParticipant.participantRole = .normal
            conversationParticipant.person = person
            conversationParticipant.conversation = conversation
        }
    }

    private static func displayName(forConversationAt index: Int) -> String {
        if index.isMultiple(of: 7) {
            return "Weekly Product Dispatch \(index)"
        }

        if index.isMultiple(of: 5) {
            return "Infra and Sync Review \(index)"
        }

        return "Project Thread \(index)"
    }

    private static func snippet(forConversationAt index: Int) -> String {
        if index.isMultiple(of: 7) {
            return "Newsletter preview content for regression coverage \(index)."
        }

        return "Conversation \(index) snippet covering HTML rendering, sync state, and message previews."
    }

    private static func bodyText(forThreadMessageAt index: Int) -> String {
        """
        Message \(index) body for deterministic thread-open benchmarking.
        It includes enough text to exercise quote stripping, line wrapping, and shared-link extraction paths.
        https://docs.google.com/document/d/thread-\(index)
        """
    }
}
