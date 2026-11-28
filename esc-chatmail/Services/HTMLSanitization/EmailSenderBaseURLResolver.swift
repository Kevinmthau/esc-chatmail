import Foundation

/// The sender's site, `https://<From domain>/`, as the base URL of an email's document (for the
/// `Referer` some image hosts require) and of the remote-image fallback's requests.
enum EmailSenderBaseURLResolver {
    /// Nil for no usable domain, and for any domain `PrivateNetworkAddressDetector` refuses (an IP
    /// literal, a `.local` or single-label name, `localhost`, every spelling the detector reads as
    /// one of those): the document then loads at `about:blank`. A sender chooses its From, and a
    /// private base let it defeat the meta-refresh guard, which had to exempt the document's own
    /// base host for the document to load at all, so a refresh to `http://127.0.0.1:8080/` from
    /// `a@127.0.0.1` was let through (architecture review 2026-11, `security-privacy#2`). A private
    /// base gives no useful `Referer`, and a relative URL resolved against it is refused by the
    /// web content rules anyway. It also mended a sender whose domain is a non-canonical private
    /// spelling (`a@127.0.0.1.`), whose own document load the guard refused once WebKit had
    /// canonicalized the host, so that email never rendered.
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

        guard let url = URL(string: "https://\(domain)/"),
              !PrivateNetworkAddressDetector.isPrivateOrReserved(url) else {
            return nil
        }
        return url
    }
}
