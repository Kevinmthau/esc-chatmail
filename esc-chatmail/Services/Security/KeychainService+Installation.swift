import Foundation

// MARK: - Installation ID Management
extension KeychainService {
    func getOrCreateInstallationId() -> String {
        if let existingId = try? loadString(for: .installationId) {
            return existingId
        }

        let newId = UUID().uuidString
        try? saveString(newId, for: .installationId, withAccess: .afterFirstUnlockThisDeviceOnly)

        // Also create installation timestamp when creating new installation ID
        setInstallationTimestamp()

        return newId
    }

    func verifyInstallationId(_ id: String) -> Bool {
        guard let storedId = try? loadString(for: .installationId) else {
            return false
        }
        return storedId == id
    }

    func getOrCreateInstallationTimestamp() -> Date {
        if let timestamp = getInstallationTimestamp() {
            return timestamp
        }

        // Create new timestamp with a 10-minute buffer in the past
        // This accounts for emails that arrived just before the app was installed
        let bufferMinutes: TimeInterval = 10 * 60
        let timestamp = Date().addingTimeInterval(-bufferMinutes)
        setInstallationTimestamp(timestamp)
        Log.debug("Created installation timestamp with 10-minute buffer: \(timestamp)", category: .auth)
        return timestamp
    }

    func getInstallationTimestamp() -> Date? {
        guard let timestampString = try? loadString(for: .installationTimestamp),
              let timestamp = Double(timestampString) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    func setInstallationTimestamp(_ date: Date = Date()) {
        let timestamp = date.timeIntervalSince1970
        try? saveString(String(timestamp), for: .installationTimestamp, withAccess: .afterFirstUnlockThisDeviceOnly)
    }

    /// Resets the installation timestamp to include older messages
    /// - Parameter minutesBack: How many minutes in the past to set the timestamp (default 30)
    func resetInstallationTimestamp(minutesBack: Int = 30) {
        let newTimestamp = Date().addingTimeInterval(-TimeInterval(minutesBack * 60))
        setInstallationTimestamp(newTimestamp)
        Log.debug("Reset installation timestamp to: \(newTimestamp) (\(minutesBack) minutes ago)", category: .auth)
    }

    /// Clears the installation timestamp so it will be recreated on next sync
    func clearInstallationTimestamp() {
        try? delete(for: .installationTimestamp)
        Log.debug("Cleared installation timestamp", category: .auth)
    }
}
