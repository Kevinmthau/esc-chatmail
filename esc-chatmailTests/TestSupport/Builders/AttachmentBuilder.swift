import Foundation
import CoreData
@testable import esc_chatmail

/// Fluent builder for creating Attachment entities in tests.
///
/// Usage:
/// ```swift
/// let attachment = AttachmentBuilder()
///     .withId("att-123")
///     .withFilename("photo.jpg")
///     .asImage()
///     .queued()
///     .build(in: context)
/// ```
final class AttachmentBuilder {
    private var id: String = UUID().uuidString
    private var filename: String = "test-file.txt"
    private var mimeType: String = "text/plain"
    private var state: Attachment.State = .queued
    private var localURL: String?
    private var previewURL: String?
    private var byteSize: Int64 = 1024
    private var pageCount: Int16 = 0
    private var width: Int16 = 0
    private var height: Int16 = 0
    private var message: Message?

    // MARK: - Fluent Setters

    func withId(_ id: String) -> Self {
        self.id = id
        return self
    }

    func withFilename(_ filename: String) -> Self {
        self.filename = filename
        return self
    }

    func withMimeType(_ mimeType: String) -> Self {
        self.mimeType = mimeType
        return self
    }

    func asImage(width: Int16 = 800, height: Int16 = 600) -> Self {
        self.mimeType = "image/jpeg"
        self.filename = "image.jpg"
        self.width = width
        self.height = height
        return self
    }

    func asPDF(pageCount: Int16 = 1) -> Self {
        self.mimeType = "application/pdf"
        self.filename = "document.pdf"
        self.pageCount = pageCount
        return self
    }

    func queued() -> Self {
        self.state = .queued
        return self
    }

    func downloading() -> Self {
        self.state = .uploading
        return self
    }

    func downloaded() -> Self {
        self.state = .downloaded
        return self
    }

    func failed() -> Self {
        self.state = .failed
        return self
    }

    func withLocalURL(_ url: String) -> Self {
        self.localURL = url
        return self
    }

    func withPreviewURL(_ url: String) -> Self {
        self.previewURL = url
        return self
    }

    func withByteSize(_ size: Int64) -> Self {
        self.byteSize = size
        return self
    }

    func forMessage(_ message: Message) -> Self {
        self.message = message
        return self
    }

    // MARK: - Build

    /// Builds the Attachment entity in the given context.
    /// - Parameter context: The managed object context to create the attachment in
    /// - Returns: The created Attachment entity
    func build(in context: NSManagedObjectContext) -> Attachment {
        let attachment = Attachment(context: context)
        attachment.id = id
        attachment.filename = filename
        attachment.mimeType = mimeType
        attachment.state = state
        attachment.localURL = localURL
        attachment.previewURL = previewURL
        attachment.byteSize = byteSize
        attachment.pageCount = pageCount
        attachment.width = width
        attachment.height = height
        attachment.message = message
        return attachment
    }
}

// MARK: - Convenience Extensions

extension AttachmentBuilder {
    /// Creates a simple queued attachment
    static func simple(in context: NSManagedObjectContext) -> Attachment {
        AttachmentBuilder().build(in: context)
    }

    /// Creates a queued image attachment
    static func queuedImage(in context: NSManagedObjectContext) -> Attachment {
        AttachmentBuilder()
            .asImage()
            .queued()
            .build(in: context)
    }

    /// Creates a downloaded image attachment with paths
    static func downloadedImage(in context: NSManagedObjectContext) -> Attachment {
        AttachmentBuilder()
            .asImage()
            .downloaded()
            .withLocalURL("Attachments/test-image.jpg")
            .withPreviewURL("Previews/test-image.jpg")
            .build(in: context)
    }

    /// Creates a failed attachment
    static func failedAttachment(in context: NSManagedObjectContext) -> Attachment {
        AttachmentBuilder()
            .asImage()
            .failed()
            .build(in: context)
    }
}
