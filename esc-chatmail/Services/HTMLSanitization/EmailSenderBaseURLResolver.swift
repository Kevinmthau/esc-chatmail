import Foundation

enum EmailSenderBaseURLResolver {
    static func baseURL(from senderEmail: String?) -> URL? {
        guard let senderEmail,
              let atIndex = senderEmail.lastIndex(of: "@") else {
            return nil
        }

        let domain = senderEmail[senderEmail.index(after: atIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !domain.isEmpty,
              domain.contains("."),
              !domain.contains(" "),
              !domain.contains("/"),
              !domain.contains("@") else {
            return nil
        }

        return URL(string: "https://\(domain)/")
    }
}
