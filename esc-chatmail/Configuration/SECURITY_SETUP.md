# Security Configuration Setup

## Overview
This project uses a secure configuration system to protect sensitive API keys and credentials. Follow these steps to set up your development environment.

## Initial Setup

### 1. Create Configuration Files
Copy the template configuration file for your environment:

```bash
cd esc-chatmail/Configuration
cp Config.xcconfig.template Debug.xcconfig
cp Config.xcconfig.template Release.xcconfig
```

### 2. Fill in Your Credentials
Edit `Debug.xcconfig` and `Release.xcconfig` with your actual Google OAuth credentials:

```
GOOGLE_CLIENT_ID = your-actual-client-id
GOOGLE_API_KEY = your-actual-api-key
GOOGLE_PROJECT_NUMBER = your-project-number
GOOGLE_PROJECT_ID = your-project-id
GOOGLE_REDIRECT_URI = com.googleusercontent.apps.your-client-id
```

### 3. Configure Xcode Project
1. Open the project in Xcode
2. Select the project in the navigator
3. Go to the project settings (not target)
4. Under "Configurations", set:
   - Debug: `Debug.xcconfig`
   - Release: `Release.xcconfig`

## Security Architecture

### Configuration Management
- **xcconfig files**: Store sensitive configuration values outside of code
- **Info.plist**: References configuration values using `$(VARIABLE_NAME)`
- **Constants.swift**: Reads values from Info.plist at runtime
- **Git**: Configuration files are excluded from version control

### Keychain Service
The `KeychainService` provides centralized, secure storage for:
- OAuth tokens
- User credentials
- Installation IDs
- Sensitive preferences

Features:
- Type-safe key definitions
- Multiple access levels (when unlocked, after first unlock, etc.)
- Automatic error handling
- Support for Codable types

### Token Manager
The `TokenManager` handles OAuth token lifecycle:
- Automatic token refresh before expiration
- Exponential backoff for retry logic
- Thread-safe token access
- Integration with Google Sign-In

Features:
- Prevents multiple simultaneous refresh attempts
- Handles network errors gracefully
- Maintains token freshness
- Secure storage in Keychain

## Usage Examples

### Saving to Keychain
```swift
let keychainService = KeychainService.shared
try keychainService.saveString("user@example.com", for: .googleUserEmail)
```

### Getting Fresh Token
```swift
let tokenManager = TokenManager.shared
let token = try await tokenManager.getCurrentToken()
```

### Making Authenticated API Calls
```swift
// TokenManager automatically handles refresh
let token = try await tokenManager.withTokenRetry { token in
    // Make API call with token
    return try await performAPICall(token: token)
}
```

## Security Best Practices

1. **Never commit** `Debug.xcconfig` or `Release.xcconfig` files
2. **Always use** KeychainService for sensitive data storage
3. **Never log** tokens or sensitive information
4. **Use** TokenManager for all OAuth token operations
5. **Rotate** API keys periodically
6. **Review** `.gitignore` to ensure sensitive files are excluded

## Troubleshooting

### "GOOGLE_CLIENT_ID not configured" Error
- Ensure xcconfig files are created and filled with actual values
- Verify Xcode project is configured to use the xcconfig files
- Clean build folder and rebuild

### Token Refresh Failures
- Check network connectivity
- Verify Google OAuth configuration
- Ensure user hasn't revoked access
- Check TokenManager logs for specific errors

### Keychain Access Issues
- Verify app has proper entitlements
- Check device/simulator keychain isn't corrupted
- Use KeychainService error messages for debugging

## Migration from Old Implementation

The new security implementation automatically migrates:
- Existing Google Sign-In sessions
- Stored installation IDs
- User preferences

No manual migration is required.