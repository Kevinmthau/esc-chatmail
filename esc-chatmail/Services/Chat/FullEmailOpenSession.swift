import Foundation
import CoreData
import Combine

struct FullEmailPlaceholder: Equatable {
    static let previewCharacterLimit = 500
    static let bodyTextPreviewScanLimit = 4_000
    private static let normalizationWhitespace = CharacterSet.whitespacesAndNewlines

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
        if let previewText = normalizedPreviewText(message.chatPreviewTextValue) {
            return previewText
        }
        if let cleanedSnippet = normalizedPreviewText(message.cleanedSnippet) {
            return cleanedSnippet
        }
        if let snippet = normalizedPreviewText(message.snippet) {
            return snippet
        }

        return normalizedBodyPreviewText(message.bodyTextValue)
    }

    private static func normalizedSingleLine(_ value: String?) -> String? {
        normalizedText(value, maxLength: 160)
    }

    private static func normalizedPreviewText(_ value: String?) -> String? {
        normalizedText(value, maxLength: previewCharacterLimit)
    }

    private static func normalizedBodyPreviewText(_ value: String?) -> String? {
        normalizedText(
            value,
            maxLength: previewCharacterLimit,
            scanLimit: bodyTextPreviewScanLimit
        )
    }

    private static func normalizedText(_ value: String?, maxLength: Int, scanLimit: Int? = nil) -> String? {
        guard let value else { return nil }
        var result = ""
        result.reserveCapacity(maxLength)
        var pendingWhitespace = false
        var scannedCharacters = 0

        for character in value {
            if let scanLimit, scannedCharacters >= scanLimit {
                break
            }
            scannedCharacters += 1

            if isWhitespaceOrNewline(character) {
                if !result.isEmpty {
                    pendingWhitespace = true
                }
                continue
            }

            if pendingWhitespace {
                guard result.count < maxLength else { break }
                result.append(" ")
                pendingWhitespace = false
            }

            guard result.count < maxLength else { break }
            result.append(character)
        }

        let collapsed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func isWhitespaceOrNewline(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { normalizationWhitespace.contains($0) }
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
