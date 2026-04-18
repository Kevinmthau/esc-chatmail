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
        case forward(ComposeForwardModeContext)
        case reply(ComposeReplyModeContext)

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            switch (lhs, rhs) {
            case (.newMessage, .newMessage): return true
            case (.newEmail, .newEmail): return true
            case (.forward(let c1), .forward(let c2)): return c1.id == c2.id
            case (.reply(let c1), .reply(let c2)):
                return c1.initialRecipients == c2.initialRecipients &&
                    c1.outboundRequestContext.conversationObjectID == c2.outboundRequestContext.conversationObjectID &&
                    c1.outboundRequestContext.replyingToMessageObjectID == c2.outboundRequestContext.replyingToMessageObjectID &&
                    c1.outboundRequestContext.optimisticConversation?.existingConversationReference == c2.outboundRequestContext.optimisticConversation?.existingConversationReference
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
    private(set) var lastSentConversationReference: ConversationReference?
    private var hasSetupMode = false

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Forward HTML Content

    /// HTML body content from forwarded message (nil for non-forward modes)
    private var forwardedHTMLBody: String?

    /// Plain text body of the forwarded message (used for MIME text part)
    private var forwardedPlainTextBody: String = ""

    /// Inline attachment infos from the forwarded message (images referenced by cid: URLs)
    private var forwardedInlineAttachmentInfos: [GmailSendService.AttachmentInfo] = []

    // MARK: - Composed Services

    let recipientManager: RecipientManager
    let autocompleteService: ContactAutocompleteService
    let attachmentManager: ComposeAttachmentManager

    private let outboundMessageCoordinator: any OutboundMessageCoordinating
    private let outboundAttachmentContextBuilder: OutboundAttachmentContextBuilder

    // MARK: - Dependencies

    let mode: Mode
    private let storage: StorageDependencies

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
        guard hasValidRecipients && !isSending else { return false }

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

    init(mode: Mode = .newMessage, dependencies: ComposeDependencies? = nil) {
        let resolvedDependencies = dependencies ?? Dependencies.shared.makeComposeDependencies()
        self.mode = mode
        self.storage = resolvedDependencies.storage

        // Initialize composed services
        self.recipientManager = resolvedDependencies.makeRecipientManager()
        self.autocompleteService = resolvedDependencies.makeContactAutocompleteService()
        self.attachmentManager = resolvedDependencies.makeComposeAttachmentManager()
        self.outboundMessageCoordinator = resolvedDependencies.messaging.makeOutboundMessageCoordinator()
        self.outboundAttachmentContextBuilder = resolvedDependencies.messaging.makeOutboundAttachmentContextBuilder()

        // Forward child observable changes to trigger view updates
        forwardChanges(from: autocompleteService, storing: &cancellables)
        forwardChanges(from: recipientManager, storing: &cancellables)
        forwardChanges(from: attachmentManager, storing: &cancellables)
    }

    func setupForMode() {
        guard !hasSetupMode else { return }
        hasSetupMode = true

        switch mode {
        case .forward(let context):
            body = ""
            subject = context.initialSubject ?? ""

            // Store HTML content for forwarding
            forwardedHTMLBody = context.forwardedHTMLBody
            forwardedPlainTextBody = context.forwardedPlainTextBody

            // Store inline attachments for forwarding (these will be included in multipart/related)
            forwardedInlineAttachmentInfos = context.forwardedInlineAttachmentInfos

            // Copy regular attachments from original message
            var skipped = 0
            for attachment in context.forwardedRegularAttachments {
                if let copied = attachmentManager.copyAttachmentForForward(attachment) {
                    attachmentManager.addAttachment(copied)
                } else {
                    skipped += 1
                }
            }
            skippedForwardAttachmentCount = skipped
        case .reply(let context):
            recipientManager.setupRecipients(context.initialRecipients)
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
        ConversationLookupService(context: storage.viewContext)
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
        lastSentConversationReference = nil
        guard canSend else { return false }

        isSending = true
        error = nil

        let result: OutboundMessageResult?
        do {
            let recipientEmails = recipients.map { $0.email }
            let request = try makeOutboundSendRequest(recipientEmails: recipientEmails)
            result = try await outboundMessageCoordinator.send(request)
        } catch {
            Log.error("Failed to create optimistic message", category: .message, error: error)
            self.error = GmailSendService.SendError.optimisticCreationFailed
            showError = true
            isSending = false
            return false
        }
        guard let result else {
            isSending = false
            return false
        }

        lastSentConversationReference = result.conversationReference
        isSending = false
        return true
    }

    private func makeOutboundSendRequest(recipientEmails: [String]) throws -> OutboundMessageRequest {
        switch mode {
        case .newMessage, .newEmail:
            return .compose(
                .init(
                    recipientEmails: recipientEmails,
                    subject: subject,
                    body: body,
                    attachments: try outboundAttachmentContextBuilder.buildSendAttachments(from: attachments),
                    optimisticConversation: makeOptimisticConversationReference(forRecipients: recipientEmails)
                )
            )

        case .forward:
            return .forward(
                .init(
                    recipientEmails: recipientEmails,
                    subject: subject,
                    body: body,
                    attachments: try outboundAttachmentContextBuilder.buildSendAttachments(from: attachments),
                    forwardedPlainTextBody: forwardedPlainTextBody,
                    forwardedHTMLBody: forwardedHTMLBody,
                    forwardedInlineAttachmentInfos: forwardedInlineAttachmentInfos,
                    optimisticConversation: makeOptimisticConversationReference(forRecipients: recipientEmails)
                )
            )

        case .reply(let context):
            return .reply(
                .init(
                    context: context.outboundRequestContext,
                    body: body,
                    attachments: try outboundAttachmentContextBuilder.buildSendAttachments(from: attachments)
                )
            )
        }
    }

    private func makeOptimisticConversationReference(
        forRecipients recipients: [String]
    ) -> OptimisticConversationReference? {
        let normalizedParticipants = Array(
            Set(recipients.map(EmailNormalizer.normalize).filter { !$0.isEmpty })
        )
        guard !normalizedParticipants.isEmpty else { return nil }

        return .participantHash(
            calculateParticipantHash(from: normalizedParticipants)
        )
    }
}
