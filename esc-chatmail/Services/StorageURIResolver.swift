import Foundation

enum StorageURIResolver {
    static func resolve(_ urlString: String) -> URL? {
        if urlString.starts(with: "/") {
            return URL(fileURLWithPath: urlString)
        }

        return URL(string: urlString)
    }
}
