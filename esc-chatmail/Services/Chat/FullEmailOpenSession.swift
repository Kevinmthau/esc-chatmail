import Foundation
import CoreData
import Combine

struct FullEmailPlaceholder: Equatable {
    let messageId: String
    let subject: String
    let senderName: String?
    let senderEmail: String?
    let previewText: String?
    let date: Date?

    var senderDisplayText: String {
        senderName ?? senderEmail ?? "Unknown Sender"
    }

    init(message: Message) {
        self.messageId = message.id
        self.subject = Self.normalizedSingleLine(message.subject) ?? "No Subject"
        self.senderName = Self.normalizedSingleLine(message.senderNameValue)
        self.senderEmail = Self.normalizedSingleLine(message.senderEmailValue)
        self.previewText = Self.previewText(for: message)
        self.date = message.internalDate
    }

    private static func previewText(for message: Message) -> String? {
        [
            message.chatPreviewTextValue,
            message.cleanedSnippet,
            message.snippet,
            message.bodyTextValue
        ]
        .lazy
        .compactMap(normalizedPreviewText)
        .first
    }

    private static func normalizedSingleLine(_ value: String?) -> String? {
        normalizedText(value, maxLength: 160)
    }

    private static func normalizedPreviewText(_ value: String?) -> String? {
        normalizedText(value, maxLength: 500)
    }

    private static func normalizedText(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }

        guard collapsed.count > maxLength else {
            return collapsed
        }

        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FullEmailOpenSessionState: Equatable {
    case presentingPreparedPayload
    case presentingPlaceholder
    case loading
    case failed(String)
}

@MainActor
final class FullEmailOpenSession: ObservableObject, Identifiable {
    let id: NSManagedObjectID
    let messageId: String
    let messageObjectID: NSManagedObjectID
    let message: Message
    let request: OriginalEmailWarmRequest
    let initialOpenPayload: FullEmailOpenPayload?
    let immediatePlaceholder: FullEmailPlaceholder

    @Published private(set) var state: FullEmailOpenSessionState

    var hasImmediateVisualSurface: Bool {
        initialOpenPayload != nil || !immediatePlaceholder.subject.isEmpty
    }

    init(
        message: Message,
        request: OriginalEmailWarmRequest,
        initialOpenPayload: FullEmailOpenPayload?,
        immediatePlaceholder: FullEmailPlaceholder
    ) {
        self.id = message.objectID
        self.messageId = message.id
        self.messageObjectID = message.objectID
        self.message = message
        self.request = request
        self.initialOpenPayload = initialOpenPayload?.messageId == message.id ? initialOpenPayload : nil
        self.immediatePlaceholder = immediatePlaceholder
        self.state = self.initialOpenPayload == nil ? .presentingPlaceholder : .presentingPreparedPayload
    }

    func markLoading() {
        state = .loading
    }

    func markFailed(_ message: String) {
        state = .failed(message)
    }
}
