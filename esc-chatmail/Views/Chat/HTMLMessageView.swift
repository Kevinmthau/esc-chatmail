import SwiftUI
import UIKit
import WebKit

// MARK: - Inline HTML Preview for Chat Bubbles
struct HTMLPreviewView: View {
    let message: Message
    let maxHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var htmlContent: String?
    @State private var isLoading = true

    private let htmlContentLoader = HTMLContentLoader.shared
    private var loadKey: String {
        "\(message.id)|\(message.bodyStorageURI ?? "")|\(message.bodyText?.hashValue ?? 0)|\(colorScheme == .dark)"
    }

    var body: some View {
        Group {
            if isLoading {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: maxHeight)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.8)
                    )
            } else if let html = htmlContent {
                HTMLPreviewWebView(
                    htmlContent: html,
                    isDarkMode: colorScheme == .dark,
                    maxHeight: maxHeight,
                    message: message
                )
                .frame(height: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 60)
                    .overlay(
                        Text("Preview unavailable")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    )
            }
        }
        .task(id: loadKey) {
            await loadHTMLContent()
        }
    }

    private func loadHTMLContent() async {
        await MainActor.run {
            if htmlContent == nil {
                isLoading = true
            }
        }

        let result = await htmlContentLoader.loadContent(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            senderEmail: message.senderEmail,
            isDarkMode: colorScheme == .dark,
            cleanupMode: message.htmlDisplayCleanupMode,
            displayPurpose: .preview
        )

        guard !Task.isCancelled else {
            return
        }

        await MainActor.run {
            self.htmlContent = result.html
            self.isLoading = false
        }
    }
}

// MARK: - Full HTML Message View
private enum OriginalEmailLoadedContent {
    case html(String)
    case plainText(String)
}

struct HTMLMessageView: View {
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedContent: OriginalEmailLoadedContent?
    @State private var isLoading = true

    private let htmlContentLoader = HTMLContentLoader.shared
    private var loadKey: String {
        "\(message.id)|\(message.bodyStorageURI ?? "")|\(message.bodyText?.hashValue ?? 0)|\(message.subject?.hashValue ?? 0)|\(message.senderEmail?.hashValue ?? 0)|\(colorScheme == .dark)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadedContent {
                    switch loadedContent {
                    case .html(let html):
                        HTMLWebView(
                            htmlContent: html,
                            isDarkMode: colorScheme == .dark,
                            message: message
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .plainText(let text):
                        OriginalEmailReadableView(message: message, text: text)
                    }
                } else {
                    ContentUnavailableView(
                        "No Content",
                        systemImage: "doc.text",
                        description: Text("The original email content is not available")
                    )
                }
            }
            .navigationTitle("Original Email")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task(id: loadKey) {
            await loadHTMLContent()
        }
    }

    private func loadHTMLContent() async {
        await MainActor.run {
            isLoading = true
        }

        Log.diagnostic(.htmlPreview, level: .info, "HTMLMessageView loading message \(message.id)", category: .ui)
        let result = await htmlContentLoader.loadContentWithTimeout(
            messageId: message.id,
            bodyStorageURI: message.bodyStorageURI,
            bodyText: message.bodyText,
            senderEmail: message.senderEmail,
            subject: message.subject,
            isDarkMode: colorScheme == .dark,
            cleanupMode: .none,
            displayPurpose: .original,
            originalHTMLPreference: .preferHTML,
            timeout: 5.0
        )

        guard !Task.isCancelled else {
            return
        }

        // If we loaded HTML from the per-message file location (or recovered it and saved it there),
        // ensure Core Data points at the canonical file URL so the rest of the UI can treat it as
        // having a stable HTML source.
        if (result.source == .messageId || result.source == .recovered),
           result.html != nil,
           let context = message.managedObjectContext {
            let messageId = message.id
            Task {
                await context.perform {
                    guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                        return
                    }
                    let messagesDirectory = documentsPath.appendingPathComponent("Messages")
                    let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
                    message.bodyStorageURI = fileURL.absoluteString
                    context.saveOrLog(operation: "update message body storage URI")
                }
            }
        }

        await MainActor.run {
            switch result.presentation {
            case .html:
                self.loadedContent = result.html.map(OriginalEmailLoadedContent.html)
            case .nativePlainText:
                self.loadedContent = result.nativeText.map(OriginalEmailLoadedContent.plainText)
            }
            self.isLoading = false
        }

        Log.diagnostic(
            .htmlPreview,
            level: .info,
            "HTMLMessageView loaded message \(message.id) source=\(String(describing: result.source)) presentation=\(result.presentation.rawValue) hasHTML=\(result.html != nil)",
            category: .ui
        )
    }
}

private struct OriginalEmailReadableView: View {
    let message: Message
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OriginalEmailMetadataCard(message: message)

                Text(Self.linkifiedAttributedString(from: text))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemBackground))
        .tint(.blue)
    }

    private static func linkifiedAttributedString(from text: String) -> AttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label
            ]
        )

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: attributed.length)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url else {
                    continue
                }
                attributed.addAttribute(.link, value: url, range: match.range)
            }
        }

        return AttributedString(attributed)
    }
}

private struct OriginalEmailMetadataCard: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let subject = message.subject?.trimmingCharacters(in: .whitespacesAndNewlines),
               !subject.isEmpty {
                Text(subject)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            if let senderLine, !senderLine.isEmpty {
                Text(senderLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(message.internalDate.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var senderLine: String? {
        let senderName = message.senderName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderEmail = message.senderEmail?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (senderName, senderEmail) {
        case let (.some(name), .some(email)) where !name.isEmpty && !email.isEmpty:
            return "\(name) <\(email)>"
        case let (_, .some(email)) where !email.isEmpty:
            return email
        case let (.some(name), _) where !name.isEmpty:
            return name
        default:
            return nil
        }
    }
}
