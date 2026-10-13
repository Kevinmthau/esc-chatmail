import Foundation

/// Recovery data for a forward, kept in the existing outbound envelope column.
/// Replies retain their original JSON representation for backwards compatibility.
struct StoredForwardEnvelope: Codable, Equatable, Sendable {
    let recipientEmails: [String]
    let subject: String?
    let authoredBody: String
    let forwardedPlainTextBody: String
    let forwardedHTMLBody: String?
    let replacingUnsentMessageID: String?
    /// A live competing attempt must still refuse admission. If it is later
    /// recovered as definitely unsent, its preserved edits become independent.
    var recoverySourceWasConsumed: Bool? = nil

    private struct Record: Codable {
        let version: Int
        let kind: String
        let forward: StoredForwardEnvelope
    }

    private struct Kind: Decodable {
        let kind: String?
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(Record(version: 1, kind: "forward", forward: self))
    }

    func withoutRecoverySource() -> Self {
        Self(recipientEmails: recipientEmails, subject: subject, authoredBody: authoredBody,
             forwardedPlainTextBody: forwardedPlainTextBody, forwardedHTMLBody: forwardedHTMLBody,
             replacingUnsentMessageID: nil)
    }

    func withConsumedRecoverySource() -> Self {
        var envelope = self
        envelope.recoverySourceWasConsumed = true
        return envelope
    }

    static func decode(from data: Data?) throws -> Self? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        guard try decoder.decode(Kind.self, from: data).kind == "forward" else {
            // Existing StoredReplyEnvelope data has no kind field.
            return nil
        }
        let record = try decoder.decode(Record.self, from: data)
        guard record.version == 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription: "Unsupported saved forward version"
            ))
        }
        return record.forward
    }
}
