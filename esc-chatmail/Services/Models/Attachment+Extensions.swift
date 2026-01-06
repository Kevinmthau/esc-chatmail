import Foundation
import CoreData

extension Attachment {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Attachment> {
        return NSFetchRequest<Attachment>(entityName: "Attachment")
    }

    @NSManaged public var id: String?
    @NSManaged public var filename: String
    @NSManaged public var mimeType: String
    @NSManaged public var stateRaw: String
    @NSManaged public var localURL: String?
    @NSManaged public var previewURL: String?
    @NSManaged public var byteSize: Int64
    @NSManaged public var pageCount: Int16
    @NSManaged public var width: Int16
    @NSManaged public var height: Int16
    @NSManaged public var message: Message?

    /// Whether this is a locally-created attachment (not yet synced)
    var isLocalAttachment: Bool {
        id?.starts(with: "local_") == true
    }

    /// Type-safe accessor for id (alias for consistency)
    var attachmentId: String? {
        id
    }

    /// Type-safe accessor for localURL (alias for consistency)
    var localURLValue: String? {
        localURL
    }

    /// Type-safe accessor for previewURL (alias for consistency)
    var previewURLValue: String? {
        previewURL
    }

    /// Type-safe accessor for filename with default
    var filenameValue: String {
        filename
    }

    /// Type-safe accessor for mimeType with default
    var mimeTypeValue: String {
        mimeType
    }
}
