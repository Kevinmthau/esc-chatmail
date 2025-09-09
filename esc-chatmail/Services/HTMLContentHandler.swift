import Foundation

class HTMLContentHandler {
    private let messagesDirectory: URL
    
    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.messagesDirectory = documentsPath.appendingPathComponent("Messages")
        createMessagesDirectoryIfNeeded()
    }
    
    private func createMessagesDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: messagesDirectory.path) {
            try? FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        }
    }
    
    func saveHTML(_ html: String, for messageId: String) -> URL? {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        
        do {
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            print("Failed to save HTML for message \(messageId): \(error)")
            return nil
        }
    }
    
    func loadHTML(from url: URL) -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            print("Failed to load HTML from \(url): \(error)")
            return nil
        }
    }
    
    func loadHTML(for messageId: String) -> String? {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        return loadHTML(from: fileURL)
    }
    
    func deleteHTML(for messageId: String) {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        try? FileManager.default.removeItem(at: fileURL)
    }
    
    func deleteAllHTML() {
        try? FileManager.default.removeItem(at: messagesDirectory)
        createMessagesDirectoryIfNeeded()
    }
    
    func htmlFileExists(for messageId: String) -> Bool {
        let fileURL = messagesDirectory.appendingPathComponent("\(messageId).html")
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    func calculateStorageSize() -> Int64 {
        var totalSize: Int64 = 0
        
        if let enumerator = FileManager.default.enumerator(at: messagesDirectory,
                                                          includingPropertiesForKeys: [.fileSizeKey],
                                                          options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }
        
        return totalSize
    }
    
    func cleanupOldFiles(olderThan days: Int) {
        let cutoffDate = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))
        
        if let enumerator = FileManager.default.enumerator(at: messagesDirectory,
                                                          includingPropertiesForKeys: [.creationDateKey],
                                                          options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if let creationDate = try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate,
                   creationDate < cutoffDate {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }
}