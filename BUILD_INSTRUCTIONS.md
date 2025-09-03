# Build Instructions for ESC ChatMail

## Fixes Applied
1. ✅ Updated Development Team ID to `PCTX8P2X4J` (matching your certificate)
2. ✅ Bundle identifier is set to `com.esc.inboxchat`
3. ✅ GoogleService-Info.plist not needed (app uses direct client ID configuration)

## To Build on Your iPhone

### Step 1: Configure Xcode Account
1. Open `esc-chatmail.xcodeproj` in Xcode
2. Go to **Xcode → Settings** (or **Xcode → Preferences** on older versions)
3. Click the **Accounts** tab
4. Click the **+** button to add your Apple ID
5. Sign in with your Apple Developer account

### Step 2: Select Your Team
1. In Xcode, select the project in the navigator
2. Select the `esc-chatmail` target
3. Go to the **Signing & Capabilities** tab
4. Ensure **Automatically manage signing** is checked
5. Select your team from the **Team** dropdown (it should show your name with team ID `PCTX8P2X4J`)

### Step 3: Connect and Build
1. Connect your iPhone via USB
2. Select your iPhone from the device dropdown (next to the scheme selector)
3. You may need to trust your developer certificate on the phone:
   - After first build attempt, go to **Settings → General → VPN & Device Management**
   - Trust your developer certificate
4. Press **Cmd+R** to build and run

## Alternative: Command Line Build
If you prefer command line after setting up Xcode account:
```bash
# List available devices
xcrun devicectl list devices

# Build for specific device (replace DEVICE_ID with your phone's ID)
xcodebuild -scheme esc-chatmail -destination 'id=DEVICE_ID' build
```

## Troubleshooting

### If "No Account for Team" error persists:
- Make sure you've added your Apple ID in Xcode Settings
- Your Apple ID needs to be enrolled in the Apple Developer Program (free tier works for device testing)

### If bundle identifier conflict:
- The app will automatically create a unique bundle ID if needed
- You can change it to something like `com.yourname.inboxchat` if preferred

### For Gmail API:
- The app is configured with OAuth client ID
- Make sure `com.esc.inboxchat` is registered in your Google Cloud Console
- Update the redirect URI in Info.plist if you change the bundle identifier