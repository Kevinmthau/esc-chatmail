import Foundation
import CoreData

class CoreDataStack {
    static let shared = CoreDataStack()
    
    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "ESCChatmail")
        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return container
    }()
    
    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }
    
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
    
    func save(context: NSManagedObjectContext) {
        context.performAndWait {
            guard context.hasChanges else { return }
            
            do {
                try context.save()
            } catch {
                let nsError = error as NSError
                print("Core Data save error: \(nsError), \(nsError.userInfo)")
                // Don't crash in production - just log the error
            }
        }
    }
    
    func destroyAllData() {
        let coordinator = persistentContainer.persistentStoreCoordinator
        
        for store in coordinator.persistentStores {
            do {
                let storeURL = store.url
                try coordinator.remove(store)
                
                if let storeURL = storeURL {
                    try FileManager.default.removeItem(at: storeURL)
                    
                    // Also remove the journal files (-wal and -shm files for SQLite)
                    let walURL = storeURL.appendingPathExtension("wal")
                    let shmURL = storeURL.appendingPathExtension("shm") 
                    try? FileManager.default.removeItem(at: walURL)
                    try? FileManager.default.removeItem(at: shmURL)
                }
            } catch {
                print("Failed to destroy Core Data store: \(error)")
            }
        }
    }
}