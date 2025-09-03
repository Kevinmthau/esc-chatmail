#!/bin/bash

echo "Adding Google Sign-In package dependency to Xcode project..."

# This script helps add the Google Sign-In dependency
# Run this in Xcode instead:

cat << 'EOF'
=================================================================
MANUAL STEPS REQUIRED IN XCODE:
=================================================================

Since the Google Sign-In package is already in your project 
(as shown by the resolved dependencies), but the module isn't 
being found, you need to:

1. Open esc-chatmail.xcodeproj in Xcode

2. Select the project in the navigator (top blue icon)

3. Select the "esc-chatmail" target

4. Go to "General" tab

5. Scroll to "Frameworks, Libraries, and Embedded Content"

6. Click the "+" button

7. Select "GoogleSignIn" from the list
   (It should already be there since packages are resolved)

8. Also add "GoogleSignInSwift" 

9. Make sure both are set to "Do Not Embed"

10. Clean build folder: Cmd+Shift+K

11. Build again: Cmd+B

Alternative method if the above doesn't work:
----------------------------------------------
1. In Xcode, go to File > Add Package Dependencies
2. Enter: https://github.com/google/GoogleSignIn-iOS
3. Version: Up to Next Major Version: 7.0.0
4. Click Add Package
5. Select both GoogleSignIn and GoogleSignInSwift
6. Click Add

=================================================================
EOF