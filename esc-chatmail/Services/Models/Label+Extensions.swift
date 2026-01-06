import Foundation
import CoreData

extension Label {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Label> {
        return NSFetchRequest<Label>(entityName: "Label")
    }

    @NSManaged public var id: String
    @NSManaged public var name: String
    @NSManaged public var messages: Set<Message>?
}
