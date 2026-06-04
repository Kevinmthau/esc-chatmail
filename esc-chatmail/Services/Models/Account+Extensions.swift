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
    @NSManaged public var sendAsAliasesJSON: String?

    var aliasesArray: [String] {
        get {
            guard let aliases = aliases else { return [] }
            return aliases.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        set {
            aliases = newValue.joined(separator: ",")
        }
    }

    var sendAsAliasesArray: [SendAsAlias] {
        get {
            guard let sendAsAliasesJSON,
                  let data = sendAsAliasesJSON.data(using: .utf8),
                  let aliases = try? JSONDecoder().decode([SendAsAlias].self, from: data) else {
                return []
            }

            return SendAsAlias.deduplicated(aliases)
        }
        set {
            let aliases = SendAsAlias.deduplicated(newValue)
            guard !aliases.isEmpty,
                  let data = try? JSONEncoder().encode(aliases),
                  let json = String(data: data, encoding: .utf8) else {
                sendAsAliasesJSON = nil
                return
            }

            sendAsAliasesJSON = json
        }
    }
}
