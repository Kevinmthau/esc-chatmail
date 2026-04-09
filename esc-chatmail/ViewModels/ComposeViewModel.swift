import Foundation
import CoreData
import Combine
import Contacts

/// Centralized ViewModel for message composition
/// Consolidates logic from NewMessageComposerView and NewMessageView
@MainActor
final class ComposeViewModel: ObservableObject {

    // MARK: - Compose Mode

    enum Mode: Equatable {
        case newMessage
        case newEmail // includes subject field
        case forward(Message)
        case reply(Conversation, Message?)

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            switch (lhs, rhs) {
            case (.newMessage, .newMessage): return true
            case (.newEmail, .newEmail): return true
            case (.forward(let m1), .forward(let m2)): return m1.objectID == m2.objectID
            case (.reply(let c1, let m1), .reply(let c2, let m2)):
                return c1.objectID == c2.objectID && m1?.objectID == m2?.objectID
            default: return false
            }
        }
    }

    // MARK: - Published State

    @Published var subject = ""
    @Published var body = ""
    @Published var isSending = false
    @Published var error: Error?
    @Published var showError = false
    @Published var skippedForwardAttachmentCount = 0
    private(set) var lastSentConversationObjectID: NSManagedObjectID?
    private var backgroundSendTasks: [String: Task<Void, Never>] = [:]
    private var hasSetupMode = false

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Forward HTML Content

    /// HTML body content from forwarded message (nil for non-forward modes)
    private var forwardedHTMLBody: String?

    /// Plain text body of the forwarded message (used for MIME text part)
    private var forwardedPlainTextBody: String = ""

    /// Inline attachments from forwarded message (images referenced by cid: URLs)
    private var forwardedInlineAttachments: [Attachment] = []

    // MARK: - Composed Services

    let recipientManager: RecipientManager
    let autocompleteService: ContactAutocompleteService
    let attachmentManager: ComposeAttachmentManager

    private let messageFormatBuilder: MessageFormatBuilder
    private let outboundMessageCoordinator: any OutboundMessageCoordinating

    // MARK: - Dependencies

    let mode: Mode
    private let dependencies: Dependencies

    // MARK: - Computed Properties

    var recipients: [Recipient] { recipientManager.recipients }
    var recipientInput: String {
        get { recipientManager.recipientInput }
        set { recipientManager.recipientInput = newValue }
    }
    var attachments: [Attachment] { attachmentManager.attachments }
    var autocompleteContacts: [ContactsService.ContactMatch] { autocompleteService.autocompleteContacts }
    var showAutocomplete: Bool { autocompleteService.showAutocomplete }
    var isForwardMode: Bool {
        if case .forward = mode { return true }
        return false
    }
    var forwardedPreviewHTML: String? { forwardedHTMLBody }
    var forwardedPreviewText: String { forwardedPlainTextBody }

    var canSend: Bool {
        let hasValidRecipients = !recipients.isEmpty && recipients.allSatisfy { $0.isValid }
        guard hasValidRecipients && !isSending && backgroundSendTasks.isEmpty else { return false }

        switch mode {
        case .forward:
            return true
        case .newMessage, .newEmail, .reply:
            return !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var showSubjectField: Bool {
        switch mode {
        case .newEmail, .forward: return true
        case .newMessage, .reply: return false
        }
    }

    var navigationTitle: String {
        switch mode {
        case .newMessage, .newEmail: return "New Message"
        case .forward: return "Forward"
        case .reply: return "Reply"
        }
    }

    // MARK: - Initialization

    init(mode: Mode = .newMessage, deps: Dependencies? = nil) {
        let resolvedDeps = deps ?? .shared
        self.mode = mode
        self.dependencies = resolvedDeps

        // Initialize composed services
        self.recipientManager = resolvedDeps.makeRecipientManager()
        self.autocompleteService = resolvedDeps.makeContactAutocompleteService()
        self.attachmentManager = resolvedDeps.makeComposeAttachmentManager()
        self.messageFormatBuilder = resolvedDeps.makeMessageFormatBuilder()
        self.outboundMessageCoordinator = resolvedDeps.makeOutboundMessageCoordinator()

        // Forward child observable changes to trigger view updates
        forwardChanges(from: autocompleteService, storing: &cancellables)
        forwardChanges(from: recipientManager, storing: &cancellables)
        forwardChanges(from: attachmentManager, storing: &cancellables)
    }

    func setupForMode() {
        guard !hasSetupMode else { return }
        hasSetupMode = true

        switch mode {
        case .forward(let message):
            let result = messageFormatBuilder.formatForwardedMessage(message)
            body = ""
            subject = result.subject ?? ""

            // Store HTML content for forwarding
            forwardedHTMLBody = result.htmlBody
            forwardedPlainTextBody = result.body

            // Store inline attachments for forwarding (these will be included in multipart/related)
            forwardedInlineAttachments = result.inlineAttachments

            // Copy regular attachments from original message
            var skipped = 0
            for original in result.attachments {
                if let copied = attachmentManager.copyAttachmentForForward(original) {
                    attachmentManager.addAttachment(copied)
                } else {
                    skipped += 1
                }
            }
            skippedForwardAttachmentCount = skipped
        case .reply(let conversation, _):
            recipientManager.setupReplyRecipients(from: conversation)
        case .newMessage, .newEmail:
            break
        }
    }

    // MARK: - Delegate Methods (passthrough to services)

    func requestContactsAccess() async {
        await autocompleteService.requestAccess()
    }

    func addRecipient(_ recipient: Recipient) {
        recipientManager.addRecipient(recipient)
    }

    func addRecipient(email: String, displayName: String? = nil) {
        recipientManager.addRecipient(email: email, displayName: displayName)
    }

    func removeRecipient(_ recipient: Recipient) {
        recipientManager.removeRecipient(recipient)
    }

    func addRecipientFromInput() {
        if recipientManager.addRecipientFromInput() {
            autocompleteService.clearAutocomplete()
        }
    }

    func searchContacts(query: String) {
        autocompleteService.searchContacts(query: query)
    }

    func selectContact(_ contact: ContactsService.ContactMatch, email: String? = nil) {
        let result = autocompleteService.selectContact(contact, email: email)
        recipientManager.addRecipient(email: result.email, displayName: result.displayName)
        recipientManager.recipientInput = ""
    }

    func clearAutocomplete() {
        autocompleteService.clearAutocomplete()
    }

    func findActiveConversation(forRecipients recipients: [String]) -> Conversation? {
        ConversationLookupService(context: dependencies.coreDataStack.viewContext)
            .findActiveConversation(forRecipients: recipients)
    }

    func addAttachment(_ attachment: Attachment) {
        attachmentManager.addAttachment(attachment)
    }

    func removeAttachment(_ attachment: Attachment) {
        attachmentManager.removeAttachment(attachment)
    }

    // MARK: - Send Message

    func send() async -> Bool {
        lastSentConversationObjectID = nil
        guard canSend else { return false }

        isSending = true
        error = nil

        let recipientEmails = recipients.map { $0.email }
        let request = makeOutboundSendRequest(recipientEmails: recipientEmails)
        let submission: OutboundMessageCoordinator.Submission?
        do {
            submission = try await outboundMessageCoordinator.send(request)
        } catch {
            Log.error("Failed to create optimistic message", category: .message, error: error)
            self.error = GmailSendService.SendError.optimisticCreationFailed
            showError = true
            isSending = false
            return false
        }
        guard let submission else {
            isSending = false
            return false
        }

        lastSentConversationObjectID = submission.conversationObjectID
        backgroundSendTasks[submission.optimisticMessageID] = submission.backgroundTask
        Task { [weak self] in
            _ = await submission.backgroundTask.result
            await MainActor.run {
                _ = self?.backgroundSendTasks.removeValue(forKey: submission.optimisticMessageID)
            }
        }

        isSending = false
        return true
    }

    private func makeOutboundSendRequest(recipientEmails: [String]) -> OutboundMessageCoordinator.Request {
        switch mode {
        case .newMessage, .newEmail:
            return .compose(
                .init(
                    recipientEmails: recipientEmails,
                    subject: subject,
                    body: body,
                    attachments: attachments
                )
            )

        case .forward:
            return .forward(
                .init(
                    recipientEmails: recipientEmails,
                    subject: subject,
                    body: body,
                    attachments: attachments,
                    forwardedPlainTextBody: forwardedPlainTextBody,
                    forwardedHTMLBody: forwardedHTMLBody,
                    forwardedInlineAttachments: forwardedInlineAttachments
                )
            )

        case .reply(let conversation, let replyingTo):
            return .reply(
                .init(
                    conversation: conversation,
                    replyingTo: replyingTo,
                    body: body,
                    attachments: attachments
                )
            )
        }
    }
}
