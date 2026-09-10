import Foundation

/// Persistence for one-shot migration "has run" flags.
///
/// Tests inject a scoped store so migration guards and completion writes do not
/// share process-global `UserDefaults.standard` state with the host app or
/// other tests running in the same process.
protocol MigrationFlagStore: AnyObject {
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Bool, forKey defaultName: String)
    func string(forKey defaultName: String) -> String?
    func setString(_ value: String?, forKey defaultName: String)
}

extension UserDefaults: MigrationFlagStore {
    func setString(_ value: String?, forKey defaultName: String) {
        set(value, forKey: defaultName)
    }
}
