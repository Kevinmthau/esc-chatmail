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

    @Published var recipients: [Recipient] = []
    @Published var recipientInput = ""
    @Published var subject = ""
    @Published var body = ""
    @Published var attachments: [Attachment] = []

    @Published var isSending = false
    @Published var error: Error?
    @Published var showError = false

    @Published var autocompleteContacts: [ContactsService.ContactMatch] = []
    @Published var showAutocomplete = false

    // MARK: - Dependencies

    let mode: Mode
    private var _sendService: GmailSendService?
    private var _contactsService: ContactsService?
    private var _viewContext: NSManagedObjectContext?

    private var viewContext: NSManagedObjectContext {
        if _viewContext == nil {
            _viewContext = CoreDataStack.shared.viewContext
        }
        return _viewContext!
    }

    private var sendService: GmailSendService {
        if _sendService == nil {
            _sendService = GmailSendService(viewContext: viewContext)
        }
        return _sendService!
    }

    private var contactsService: ContactsService {
        if _contactsService == nil {
            _contactsService = ContactsService()
        }
        return _contactsService!
    }

    // MARK: - Debouncing

    private var searchTask: Task<Void, Never>?
    private let searchDebounceInterval: UInt64 = 150_000_000 // 150ms in nanoseconds

    // MARK: - Computed Properties

    var canSend: Bool {
        !recipients.isEmpty &&
        recipients.allSatisfy { $0.isValid } &&
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSending
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

    init(mode: Mode = .newMessage) {
        self.mode = mode
        // All dependencies are lazy-initialized to avoid blocking sheet presentation
    }

    func setupForMode() {
        switch mode {
        case .forward(let message):
            setupForwardedMessage(message)
        case .reply(let conversation, _):
            setupReplyRecipients(conversation)
        case .newMessage, .newEmail:
            break
        }
    }

    // MARK: - Contact Access

    func requestContactsAccess() async {
        if contactsService.authorizationStatus == .notDetermined {
            _ = await contactsService.requestAccess()
        }
    }

    // MARK: - Recipient Management

    func addRecipient(_ recipient: Recipient) {
        guard !recipients.contains(where: { $0.email == recipient.email }) else { return }
        recipients.append(recipient)
    }

    func addRecipient(email: String, displayName: String? = nil) {
        let recipient = Recipient(email: email, displayName: displayName)
        addRecipient(recipient)
    }

    func removeRecipient(_ recipient: Recipient) {
        recipients.removeAll { $0.id == recipient.id }
    }

    func addRecipientFromInput() {
        let trimmed = recipientInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, EmailValidator.isValid(trimmed) else { return }

        let normalized = EmailNormalizer.normalize(trimmed)
        guard !recipients.contains(where: { $0.email == normalized }) else { return }

        recipients.append(Recipient(email: trimmed))
        recipientInput = ""
        clearAutocomplete()
    }

    // MARK: - Contact Search (Debounced)

    func searchContacts(query: String) {
        // Cancel any pending search
        searchTask?.cancel()

        guard !query.isEmpty else {
            clearAutocomplete()
            return
        }

        // Debounce: wait before searching
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: searchDebounceInterval)
            } catch {
                return // Task was cancelled
            }

            guard !Task.isCancelled else { return }

            let matches = await contactsService.searchContacts(query: query)

            guard !Task.isCancelled else { return }

            autocompleteContacts = matches
            showAutocomplete = !matches.isEmpty
        }
    }

    func selectContact(_ contact: ContactsService.ContactMatch, email: String? = nil) {
        let selectedEmail = email ?? contact.primaryEmail
        addRecipient(email: selectedEmail, displayName: contact.displayName)
        recipientInput = ""
        clearAutocomplete()
    }

    func clearAutocomplete() {
        searchTask?.cancel()
        autocompleteContacts = []
        showAutocomplete = false
    }

    // MARK: - Attachment Management

    func addAttachment(_ attachment: Attachment) {
        attachments.append(attachment)
    }

    func removeAttachment(_ attachment: Attachment) {
        guard let index = attachments.firstIndex(of: attachment) else { return }
        let removed = attachments.remove(at: index)

        // Clean up files if it's a local attachment
        if let attachmentId = removed.value(forKey: "id") as? String,
           attachmentId.starts(with: "local_") {
            if let localURL = removed.value(forKey: "localURL") as? String {
                AttachmentPaths.deleteFile(at: localURL)
            }
            if let previewURL = removed.value(forKey: "previewURL") as? String {
                AttachmentPaths.deleteFile(at: previewURL)
            }
        }

        viewContext.delete(removed)
    }

    // MARK: - Send Message

    func send() async -> Bool {
        guard canSend else { return false }

        isSending = true
        error = nil

        let recipientEmails = recipients.map { $0.email }
        let messageBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageSubject = subject.isEmpty ? nil : subject

        // Create optimistic message
        let optimisticMessage = sendService.createOptimisticMessage(
            to: recipientEmails,
            body: messageBody,
            subject: messageSubject,
            attachments: attachments
        )
        let optimisticMessageID = optimisticMessage.id

        // Mark attachments as uploaded immediately so they display non-dimmed
        sendService.markAttachmentsAsUploaded(attachments)

        // Prepare attachment infos for background send
        let attachmentInfos = attachments.map { sendService.attachmentToInfo($0) }

        // Capture mode data before dismissing
        let capturedMode = mode

        // Send in background - don't wait for completion
        Task.detached { [sendService] in
            do {
                let result: GmailSendService.SendResult

                switch capturedMode {
                case .reply(let conversation, let replyingTo):
                    let replyData = await MainActor.run {
                        self.buildReplyData(
                            conversation: conversation,
                            replyingTo: replyingTo,
                            body: messageBody
                        )
                    }
                    result = try await sendService.sendReply(
                        to: replyData.recipients,
                        body: replyData.body,
                        subject: replyData.subject ?? "",
                        threadId: replyData.threadId ?? "",
                        inReplyTo: replyData.inReplyTo,
                        references: replyData.references,
                        originalMessage: replyData.originalMessage,
                        attachmentInfos: attachmentInfos
                    )
                default:
                    result = try await sendService.sendNew(
                        to: recipientEmails,
                        body: messageBody,
                        subject: messageSubject,
                        attachmentInfos: attachmentInfos
                    )
                }

                // Update optimistic message with real IDs
                await MainActor.run {
                    if let message = sendService.fetchMessage(byID: optimisticMessageID) {
                        sendService.updateOptimisticMessage(message, with: result)
                    }
                }

                // Trigger sync to fetch the sent message from Gmail
                try? await SyncEngine.shared.performIncrementalSync()

            } catch {
                // Mark attachments as failed so they show error indicator
                await MainActor.run {
                    if let message = sendService.fetchMessage(byID: optimisticMessageID),
                       let attachmentsSet = message.value(forKey: "attachments") as? Set<Attachment> {
                        sendService.markAttachmentsAsFailed(Array(attachmentsSet))
                    }
                }
                print("Background send failed: \(error.localizedDescription)")
            }
        }

        isSending = false
        return true
    }

    // MARK: - Reply Data Builder

    struct ReplyData {
        let recipients: [String]
        let body: String
        let subject: String?
        let threadId: String?
        let inReplyTo: String?
        let references: [String]
        let originalMessage: QuotedMessage?
    }

    private func buildReplyData(
        conversation: Conversation,
        replyingTo: Message?,
        body: String
    ) -> ReplyData {
        let currentUserEmail = AuthSession.shared.userEmail ?? ""

        // Extract participants from conversation
        let participantEmails = Array(conversation.participants ?? [])
            .compactMap { $0.person?.email }
        let recipients = participantEmails.filter {
            EmailNormalizer.normalize($0) != EmailNormalizer.normalize(currentUserEmail)
        }

        var subject: String?
        var threadId: String?
        var inReplyTo: String?
        var references: [String] = []
        var originalMessage: QuotedMessage?

        if let replyingTo = replyingTo {
            subject = replyingTo.subject.map { MimeBuilder.prefixSubjectForReply($0) }
            threadId = replyingTo.gmThreadId
            inReplyTo = replyingTo.value(forKey: "messageId") as? String

            // Build references chain
            if let previousRefs = replyingTo.value(forKey: "references") as? String, !previousRefs.isEmpty {
                references = previousRefs.split(separator: " ").map(String.init)
            }
            if let messageId = replyingTo.value(forKey: "messageId") as? String {
                references.append(messageId)
            }

            // Store original message info for quoting
            originalMessage = QuotedMessage(
                senderName: replyingTo.value(forKey: "senderName") as? String,
                senderEmail: (replyingTo.value(forKey: "senderEmail") as? String) ?? "",
                date: replyingTo.internalDate,
                body: replyingTo.value(forKey: "bodyText") as? String
            )
        } else {
            // Find latest message in conversation
            let latestMessage = Array(conversation.messages ?? [])
                .sorted { $0.internalDate > $1.internalDate }
                .first
            threadId = latestMessage?.gmThreadId
        }

        return ReplyData(
            recipients: recipients,
            body: body,
            subject: subject,
            threadId: threadId,
            inReplyTo: inReplyTo,
            references: references,
            originalMessage: originalMessage
        )
    }

    // MARK: - Forward Setup

    private func setupForwardedMessage(_ message: Message) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var quotedText = "\n\n---------- Forwarded message ---------\n"

        // Get sender info
        let participants = Array(message.conversation?.participants ?? [])

        if message.isFromMe {
            quotedText += "From: \(AuthSession.shared.userEmail ?? "Me")\n"
        } else {
            if let otherParticipant = participants.first(where: { participant in
                let email = participant.person?.email ?? ""
                return EmailNormalizer.normalize(email) != EmailNormalizer.normalize(AuthSession.shared.userEmail ?? "")
            })?.person {
                quotedText += "From: \(otherParticipant.name ?? otherParticipant.email)\n"
            }
        }

        quotedText += "Date: \(formatter.string(from: message.internalDate))\n"

        if let originalSubject = message.subject, !originalSubject.isEmpty {
            quotedText += "Subject: \(originalSubject)\n"

            // Set subject with Fwd: prefix
            if originalSubject.lowercased().hasPrefix("fwd:") || originalSubject.lowercased().hasPrefix("fw:") {
                subject = originalSubject
            } else {
                subject = "Fwd: \(originalSubject)"
            }
        }

        let recipientList = participants.compactMap { $0.person?.email }
            .filter { EmailNormalizer.normalize($0) != EmailNormalizer.normalize(AuthSession.shared.userEmail ?? "") }

        if !recipientList.isEmpty {
            quotedText += "To: \(recipientList.joined(separator: ", "))\n"
        }

        quotedText += "\n"

        if let snippet = message.snippet {
            quotedText += snippet
        }

        body = quotedText
    }

    // MARK: - Reply Setup

    private func setupReplyRecipients(_ conversation: Conversation) {
        let currentUserEmail = AuthSession.shared.userEmail ?? ""
        let participantEmails = Array(conversation.participants ?? [])
            .compactMap { $0.person?.email }
            .filter { EmailNormalizer.normalize($0) != EmailNormalizer.normalize(currentUserEmail) }

        for email in participantEmails {
            // Try to get display name from person
            if let participant = conversation.participants?.first(where: { $0.person?.email == email }),
               let person = participant.person {
                recipients.append(Recipient(from: person))
            } else {
                recipients.append(Recipient(email: email))
            }
        }
    }
}
