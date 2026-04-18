import CoreData

struct StorageDependencies {
    let viewContext: NSManagedObjectContext
    let makeBackgroundContext: () -> NSManagedObjectContext
    let saveIfNeeded: (NSManagedObjectContext) -> Void
    let personCache: PersonCache
    let profilePhotoResolver: ProfilePhotoResolver
}
