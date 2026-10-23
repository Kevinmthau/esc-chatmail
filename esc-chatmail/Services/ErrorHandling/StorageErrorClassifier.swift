import Foundation
import CoreData

/// The one definition of "the device is out of space", plus the error-chain
/// walk the Core Data store-load classifier shares with it.
///
/// Core Data rarely reports the cause at the top level. A full disk at store
/// open arrives as `NSFileReadUnknownError` (256) or as a migration error,
/// with the SQLite result code under `userInfo["NSSQLiteErrorDomain"]` or
/// further down an `NSUnderlyingErrorKey` chain, so a check of `error.code`
/// alone misses it. Every out-of-space decision goes through `isOutOfSpace`;
/// do not add a second, narrower one.
enum StorageErrorClassifier {
    /// SQLite primary result codes (sqlite3.h). An extended code keeps its
    /// primary code in the low byte, e.g. SQLITE_IOERR_WRITE is 778 (10 | 3 << 8).
    enum SQLiteResultCode {
        static let permissionDenied = 3
        static let busy = 5
        static let locked = 6
        static let ioError = 10
        static let corrupt = 11
        static let full = 13
        static let cannotOpen = 14
        static let authorizationDenied = 23
        static let notADatabase = 26
    }

    /// Caps the chain walk so a cyclic or pathological userInfo graph cannot
    /// hang a launch.
    private static let maximumChainLength = 32

    /// True when the error, or anything it wraps, reports a full volume:
    /// `NSFileWriteOutOfSpaceError` (640), POSIX `ENOSPC` or `EDQUOT`, or
    /// `SQLITE_FULL`.
    static func isOutOfSpace(_ error: Error) -> Bool {
        let wrapsOutOfSpaceError = errorChain(error).contains { error in
            switch error.domain {
            case NSCocoaErrorDomain:
                return error.code == NSFileWriteOutOfSpaceError
            case NSPOSIXErrorDomain:
                return error.code == Int(ENOSPC) || error.code == Int(EDQUOT)
            default:
                return false
            }
        }
        return wrapsOutOfSpaceError
            || sqlitePrimaryResultCodes(in: error).contains(SQLiteResultCode.full)
    }

    /// The error followed by everything reachable through
    /// `NSUnderlyingErrorKey`, `NSMultipleUnderlyingErrorsKey` and Core Data's
    /// `NSDetailedErrorsKey`, breadth first.
    static func errorChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var queue: [NSError] = [error as NSError]
        while !queue.isEmpty, chain.count < maximumChainLength {
            let next = queue.removeFirst()
            guard !chain.contains(where: { $0 === next }) else { continue }
            chain.append(next)
            if let underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }
            if let underlying = next.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                queue.append(contentsOf: underlying)
            }
            if let detailed = next.userInfo[NSDetailedErrorsKey] as? [NSError] {
                queue.append(contentsOf: detailed)
            }
        }
        return chain
    }

    /// SQLite primary result codes found anywhere in the chain: the code of an
    /// `NSSQLiteErrorDomain` error, and the code Core Data stores under
    /// `userInfo[NSSQLiteErrorDomain]` on the Cocoa error that wraps it.
    static func sqlitePrimaryResultCodes(in error: Error) -> Set<Int> {
        var codes = Set<Int>()
        for error in errorChain(error) {
            if error.domain == NSSQLiteErrorDomain {
                codes.insert(error.code & 0xFF)
            }
            if let code = (error.userInfo[NSSQLiteErrorDomain] as? NSNumber)?.intValue {
                codes.insert(code & 0xFF)
            }
        }
        return codes
    }
}
