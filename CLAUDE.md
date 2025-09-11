# ESC ChatMail - Developer Notes

## App Deletion & Reinstall Cleanup

When the app is deleted and reinstalled, the following cleanup actions are performed automatically on first launch:

### 1. Fresh Install Detection
- Uses a unique installation ID stored in both UserDefaults and Keychain
- On launch, verifies if the IDs match - mismatch indicates fresh install
- Automatically triggers cleanup when fresh install is detected

### 2. Google Authentication Cleanup
- Signs out the user from Google Sign-In
- Revokes OAuth tokens via `GIDSignIn.disconnect()`
- Clears all authentication state
- Prevents automatic session restoration on fresh installs

### 3. Data Cleanup
- **Keychain**: Clears all stored credentials and secure data (including Google tokens)
- **Core Data**: Complete removal of persistent stores and database files
- **Attachment Cache**: Clears all cached images and data from memory
- **Attachment Files**: Removes all downloaded attachments from:
  - Documents/Attachments directory
  - Cache/AttachmentCache directory
  - Temporary directory
- **User Defaults**: Removes all app preferences and settings

### 4. Implementation Details

The cleanup is handled in two ways:

#### Fresh Install Detection (Primary Method)
- `checkAndClearKeychainOnFreshInstall()` in esc_chatmailApp.swift:45-67
- Runs on every app launch to detect fresh installations
- Uses installation ID verification between UserDefaults and Keychain
- Automatically clears all data and signs out when fresh install detected

#### App Termination (Secondary)
- `applicationWillTerminate(_:)` in AppDelegate
- Attempts cleanup when app terminates (though not called on app deletion)

Key components:
- `performFreshInstallCleanup()`: Main cleanup orchestrator
- `AuthSession.signOutAndDisconnect()`: Handles Google logout and token revocation
- `CoreDataStack.destroyAllData()`: Removes Core Data stores and files
- `AttachmentCache.clearCache(level: .aggressive)`: Clears all memory caches
- Keychain cleanup removes all secure storage items

### Testing Notes

To test the cleanup functionality:
1. Install the app and sign in with Google
2. Use the app to download some attachments
3. Delete the app from the device
4. Reinstall the app
5. Verify you are logged out and need to sign in again

The cleanup ensures user privacy and complete data removal when the app is reinstalled.