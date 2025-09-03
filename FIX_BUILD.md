# Fix Build Issues

## Current Error:
Info.plist is being copied twice - it's in the Copy Bundle Resources phase when it shouldn't be.

## Quick Fix in Xcode:

1. **Open Xcode** (already opened with `esc-chatmail.xcodeproj`)

2. **Select the project** in navigator (blue icon at top)

3. **Select "esc-chatmail" target**

4. **Go to "Build Phases" tab**

5. **Expand "Copy Bundle Resources"**

6. **Find "Info.plist" in the list and remove it** (select it and press the minus button)
   - Info.plist should NOT be in Copy Bundle Resources
   - It's automatically processed by Xcode

7. **Clean and Build** (Cmd+Shift+K then Cmd+B)

## Alternative CLI Fix:
After removing Info.plist from Copy Bundle Resources in Xcode, you can build via:
```bash
xcodebuild -scheme esc-chatmail -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

## Why this happened:
When we reorganized files, Xcode's automatic file management incorrectly added Info.plist to the Copy Bundle Resources phase. Info.plist is a special file that should be processed separately, not copied as a resource.