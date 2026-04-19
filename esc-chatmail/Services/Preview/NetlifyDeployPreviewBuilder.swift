import Foundation

/// Builds a native preview model for Netlify deploy-preview comments that arrive
/// as GitHub notification emails. Self-gating: returns `nil` for anything other
/// than a genuine `netlify[bot]` "Deploy Preview for <project>" comment, so it
/// is safe to call unconditionally ahead of the classifier-driven routes.
struct NetlifyDeployPreviewBuilder {
    func buildPreview(
        canonicalHTML: String,
        senderEmail: String?,
        subject: String? = nil
    ) -> NetlifyDeployPreviewModel? {
        guard isGitHubNotificationSender(senderEmail) else {
            return nil
        }

        let lowercasedHTML = canonicalHTML.lowercased()
        let plainText = normalizedText(TextProcessing.extractPlainText(from: canonicalHTML))
        let lowercasedPlainText = plainText.lowercased()

        guard containsNetlifyBotMarker(lowercasedHTML: lowercasedHTML, lowercasedPlainText: lowercasedPlainText) else {
            return nil
        }

        guard let heading = matchDeployHeading(in: plainText) ?? matchDeployHeading(in: plainText.replacingOccurrences(of: "\n", with: " ")) else {
            return nil
        }

        let commitSHA = extractCommitSHA(fromHTML: canonicalHTML, plainText: plainText)
        let deployLogURL = extractDeployLogURL(fromHTML: canonicalHTML, plainText: plainText)
        let repoSlug = extractRepoSlug(from: subject)

        return NetlifyDeployPreviewModel(
            title: "Deploy Preview for \(heading.project)",
            status: heading.status,
            project: heading.project,
            repoSlug: repoSlug,
            commitSHA: commitSHA,
            deployLogURL: deployLogURL,
            sourceLabel: "Netlify"
        )
    }

    // MARK: - Predicates

    private func isGitHubNotificationSender(_ senderEmail: String?) -> Bool {
        guard let senderEmail = senderEmail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !senderEmail.isEmpty else {
            return false
        }

        return senderEmail.contains("notifications@github.com")
            || senderEmail.contains("noreply@github.com")
    }

    private func containsNetlifyBotMarker(lowercasedHTML: String, lowercasedPlainText: String) -> Bool {
        if lowercasedHTML.contains("netlify[bot]") || lowercasedHTML.contains("netlify%5Bbot%5D") {
            return true
        }

        return lowercasedPlainText.contains("netlify[bot]")
    }

    // MARK: - Heading parsing

    private func matchDeployHeading(in text: String) -> DeployHeading? {
        let pattern = #"Deploy Preview for\s+([A-Za-z0-9._/-]+?)\s+(?:is\s+)?(ready|processing|failing|failed)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges >= 3,
              let projectRange = Range(match.range(at: 1), in: text),
              let statusRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let project = String(text[projectRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let statusWord = String(text[statusRange]).lowercased()

        guard !project.isEmpty else {
            return nil
        }

        let status: NetlifyDeployStatus
        switch statusWord {
        case "ready":
            status = .ready
        case "processing":
            status = .processing
        case "failed", "failing":
            status = .failed
        default:
            return nil
        }

        return DeployHeading(project: project, status: status)
    }

    // MARK: - Table field extraction

    private func extractCommitSHA(fromHTML html: String, plainText: String) -> String? {
        let tablePattern = #"Latest commit[^<]*</td>\s*<td[^>]*>\s*(?:<[^>]+>\s*)*([0-9a-f]{7,40})"#
        if let match = firstCaptureGroup(in: html, pattern: tablePattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            return String(match.prefix(7))
        }

        if let range = plainText.range(of: "Latest commit", options: .caseInsensitive) {
            let window = plainText[range.upperBound...].prefix(120)
            if let shaRange = window.range(of: #"\b[0-9a-f]{7,12}\b"#, options: .regularExpression) {
                return String(window[shaRange].prefix(7))
            }
        }

        return nil
    }

    private func extractDeployLogURL(fromHTML html: String, plainText: String) -> String? {
        let hrefPattern = #"href=["'](https://app\.netlify\.com/projects/[^"'<>\s]+/deploys/[A-Za-z0-9]+)["']"#
        if let match = firstCaptureGroup(in: html, pattern: hrefPattern, options: [.caseInsensitive]) {
            return match
        }

        let plainPattern = #"https://app\.netlify\.com/(?:projects|sites)/[A-Za-z0-9._/-]+/deploys/[A-Za-z0-9]+"#
        if let range = plainText.range(of: plainPattern, options: .regularExpression) {
            return String(plainText[range])
        }

        if let range = html.range(of: plainPattern, options: .regularExpression) {
            return String(html[range])
        }

        return nil
    }

    // MARK: - Subject parsing

    private func extractRepoSlug(from subject: String?) -> String? {
        guard let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty else {
            return nil
        }

        guard let match = firstCaptureGroup(
            in: subject,
            pattern: #"^(?:Re:\s*)?\[([^\]]+)\]"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let trimmed = match.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Utilities

    private func firstCaptureGroup(in text: String, pattern: String, options: NSRegularExpression.Options) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[range])
    }

    private func normalizedText(_ text: String) -> String {
        HTMLEntityDecoder.decode(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct DeployHeading {
    let project: String
    let status: NetlifyDeployStatus
}
