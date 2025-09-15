# Linking XCConfig Files to Xcode Project

## Quick Setup Instructions

To properly link the configuration files and remove the hardcoded credentials:

### Step 1: Open Project Settings
1. Open `esc-chatmail.xcodeproj` in Xcode
2. Click on the project name (esc-chatmail) in the navigator
3. Select the **PROJECT** (not the target) in the editor

### Step 2: Link Configuration Files
1. In the project settings, find the **Configurations** section
2. For each configuration row:
   - **Debug**: Click the arrow and select `esc-chatmail/Configuration/Debug.xcconfig`
   - **Release**: Click the arrow and select `esc-chatmail/Configuration/Release.xcconfig`

### Step 3: Verify Setup
1. Build and run the project
2. Check the console for the configuration status message
3. The app should now use the values from your xcconfig files

### Step 4: Remove Fallback Values (Optional)
Once the xcconfig files are properly linked, you can remove the fallback values from `Constants.swift`:

1. Open `Services/Constants.swift`
2. Change each property to use `fatalError` instead of returning hardcoded values
3. This ensures credentials are never hardcoded in production

## Troubleshooting

### "GOOGLE_CLIENT_ID not configured" Error
- Ensure the xcconfig files exist in `esc-chatmail/Configuration/`
- Verify they contain actual values (not placeholder text)
- Check that Xcode has linked them in project settings

### Values Still Show as $(VARIABLE_NAME)
- Clean build folder: Product → Clean Build Folder (⇧⌘K)
- Restart Xcode
- Ensure xcconfig files are properly linked in project settings

### App Crashes on Launch
The app currently has fallback values to prevent crashes. If you see crashes:
1. Check that xcconfig files exist and have valid values
2. Ensure they're not in .gitignore if you need them for testing
3. Use the fallback mechanism in Constants.swift temporarily

## Security Notes

⚠️ **NEVER commit Debug.xcconfig or Release.xcconfig to version control**

These files contain sensitive API keys and should remain local to each developer's machine.

## Current Status

The project is configured with:
- ✅ Fallback values for development (temporary)
- ✅ XCConfig templates in place
- ✅ Proper .gitignore entries
- ⏳ Awaiting Xcode project configuration linking

Once you link the xcconfig files in Xcode, the configuration will be complete and secure.