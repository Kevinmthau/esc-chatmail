# ESC Chatmail - Setup Guide

## ✅ Current Status
The project builds successfully! The Google Sign-In dependencies are already resolved in your project.

## 🚀 Quick Start

### To Run the App in Xcode:

1. **Open the project**
   ```bash
   open esc-chatmail.xcodeproj
   ```

2. **Verify Bundle Identifier**
   - Select the project (blue icon) in navigator
   - Select "esc-chatmail" target
   - General tab → Bundle Identifier: `com.esc.InboxChat`

3. **Run the app**
   - Select an iPhone simulator (e.g., iPhone 15)
   - Press ⌘R or click the Run button

## 📱 What You'll See

1. **Sign-In Screen**: Google Sign-In button
2. **After Authentication**: 
   - Initial sync will download your Gmail messages
   - Progress indicator shows sync status
3. **Main Interface**:
   - **Chats Tab**: Conversations grouped by participants
   - **Inbox Tab**: Traditional message list view
   - **Settings Tab**: Account info and sync controls

## 🔧 If You Get "No such module 'GoogleSignIn'" Error

Even though packages are resolved, Xcode sometimes needs explicit linking:

1. In Xcode → Project Navigator → Select "esc-chatmail" (blue icon)
2. Select the "esc-chatmail" target
3. General tab → "Frameworks, Libraries, and Embedded Content"
4. Click "+" → Add:
   - GoogleSignIn
   - GoogleSignInSwift
5. Set both to "Do Not Embed"
6. Clean Build Folder (⌘⇧K)
7. Build again (⌘B)

## 🔑 Google Cloud Setup Verification

The app is configured with your credentials:
- **Client ID**: 999923476073-b4m4r3o96gv30rqmo71qo210oa46au74.apps.googleusercontent.com
- **Project**: esc-gmail-client

Ensure in [Google Cloud Console](https://console.cloud.google.com):
1. Gmail API is enabled
2. OAuth consent screen is configured
3. iOS client has bundle ID: `com.esc.InboxChat`

## 📋 Features Working

- ✅ OAuth 2.0 authentication via Google Sign-In
- ✅ Gmail REST API integration
- ✅ Message syncing with Core Data persistence
- ✅ Smart conversation grouping (1:1, group, mailing lists)
- ✅ Chat-style UI with message bubbles
- ✅ Swipe actions (archive, mark read)
- ✅ HTML message rendering
- ✅ Incremental sync with Gmail History API
- ✅ Optimistic UI updates with server reconciliation

## 🐛 Troubleshooting

### Build Errors
```bash
# Clean derived data
rm -rf ~/Library/Developer/Xcode/DerivedData/esc-chatmail-*

# Resolve packages
xcodebuild -resolvePackageDependencies -project esc-chatmail.xcodeproj
```

### Sign-In Issues
- Check internet connection
- Verify bundle ID matches Google Cloud Console
- Ensure test account has Gmail API access

### Sync Issues
- First sync may take time with many messages
- Check Settings tab for sync status
- Pull to refresh on conversation list

## 📝 Notes

- The app uses your REAL Gmail data
- Messages are cached locally in Core Data
- HTML bodies are stored in Documents directory
- Supports offline viewing of synced messages