import Foundation
import CoreData

extension Account {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<Account> {
        return NSFetchRequest<Account>(entityName: "Account")
    }

    @NSManaged public var id: String
    @NSManaged public var email: String
    @NSManaged public var historyId: String?
    @NSManaged public var aliases: String? // Comma-separated list of email aliases

    var aliasesArray: [String] {
        get {
            guard let aliases = aliases else { return [] }
            return aliases.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        set {
            aliases = newValue.joined(separator: ",")
        }
    }
}
