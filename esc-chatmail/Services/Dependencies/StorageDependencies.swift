import CoreData

struct StorageDependencies {
    let viewContext: NSManagedObjectContext
    let makeBackgroundContext: () -> NSManagedObjectContext
    let saveIfNeeded: (NSManagedObjectContext) -> Bool
    let migrationFlags: MigrationFlagStore
    let personCache: PersonCache
    let profilePhotoResolver: ProfilePhotoResolver
}
