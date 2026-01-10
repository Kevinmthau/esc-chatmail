import Foundation

// MARK: - Installation ID Management
extension KeychainService {
    func getOrCreateInstallationId() -> String {
        do {
            let existingId = try loadString(for: .installationId)
            return existingId
        } catch {
            Log.warning("Failed to load installation ID, will create new one", category: .auth)
        }

        let newId = UUID().uuidString
        do {
            try saveString(newId, for: .installationId, withAccess: .afterFirstUnlockThisDeviceOnly)
        } catch {
            Log.error("Failed to save installation ID", category: .auth, error: error)
        }

        // Also create installation timestamp when creating new installation ID
        setInstallationTimestamp()

        return newId
    }

    func verifyInstallationId(_ id: String) -> Bool {
        do {
            let storedId = try loadString(for: .installationId)
            return storedId == id
        } catch {
            Log.warning("Failed to verify installation ID", category: .auth)
            return false
        }
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
        do {
            let timestampString = try loadString(for: .installationTimestamp)
            guard let timestamp = Double(timestampString) else {
                return nil
            }
            return Date(timeIntervalSince1970: timestamp)
        } catch {
            Log.warning("Failed to load installation timestamp", category: .auth)
            return nil
        }
    }

    func setInstallationTimestamp(_ date: Date = Date()) {
        let timestamp = date.timeIntervalSince1970
        do {
            try saveString(String(timestamp), for: .installationTimestamp, withAccess: .afterFirstUnlockThisDeviceOnly)
        } catch {
            Log.error("Failed to save installation timestamp", category: .auth, error: error)
        }
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
        do {
            try delete(for: .installationTimestamp)
            Log.debug("Cleared installation timestamp", category: .auth)
        } catch {
            Log.warning("Failed to clear installation timestamp", category: .auth)
        }
    }
}
