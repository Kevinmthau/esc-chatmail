# ESC Chatmail - Chat-style Gmail Client for iOS

A modern, chat-style Gmail client for iOS 17+ built with SwiftUI, Core Data, and the Gmail REST API.

## Setup Instructions

### 1. Add Google Sign-In Package Dependency

In Xcode:
1. Select your project in the navigator
2. Select the "esc-chatmail" target
3. Go to the "General" tab
4. Click the "+" button under "Frameworks, Libraries, and Embedded Content"
5. Click "Add Package Dependency"
6. Enter the URL: `https://github.com/google/GoogleSignIn-iOS`
7. Select version: Up to Next Major Version: 7.0.0
8. Click "Add Package"
9. Select "GoogleSignIn" and "GoogleSignInSwift" libraries
10. Click "Add"

### 2. Configure Bundle Identifier

1. In Xcode, select your project
2. Select the "esc-chatmail" target
3. Go to the "General" tab
4. Change Bundle Identifier to: `com.esc.InboxChat`

### 3. Google Cloud Console Configuration

The app uses these credentials:
- **CLIENT_ID**: 999923476073-b4m4r3o96gv30rqmo71qo210oa46au74.apps.googleusercontent.com
- **PROJECT_ID**: esc-gmail-client
- **PROJECT_NUMBER**: 999923476073

In the [Google Cloud Console](https://console.cloud.google.com):
1. Select project "esc-gmail-client" (or create it if needed)
2. Enable the Gmail API
3. Configure OAuth consent screen
4. Add iOS client with bundle ID: `com.esc.InboxChat`

### 4. Build and Run

1. Open the project in Xcode 15+
2. Select your target device/simulator (iOS 17+)
3. Build and run (⌘R)

## Features

- **OAuth Authentication**: Secure Google Sign-In
- **Chat-style Interface**: Conversations grouped by participants
- **Smart Grouping**: Automatic conversation threading
- **Message Actions**: Archive, mark read/unread, star, delete
- **Incremental Sync**: Efficient syncing with Gmail
- **Core Data Storage**: Offline access to messages
- **HTML Rendering**: WebKit-based message viewing

## Architecture

- **SwiftUI**: Modern declarative UI
- **Core Data**: Local data persistence
- **Gmail REST API**: Direct API integration
- **Google Sign-In**: OAuth 2.0 authentication
- **Combine**: Reactive programming

## Project Structure

```
esc-chatmail/
├── Auth/              # Authentication handling
├── API/               # Gmail API client
├── CoreData/          # Data models and stack
├── Sync/              # Sync engine
├── Views/             # SwiftUI views
├── Actions/           # Message actions
├── Utils/             # Utilities (email normalization, etc.)
└── Config/            # Configuration and constants
```

## Requirements

- iOS 17.0+
- Xcode 15.0+
- Swift 5.9+

## License

This project is for demonstration purposes.