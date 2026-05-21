# Xcode Cloud Setup

This repository now includes the project-side requirements to build and distribute `esc-chatmail` with Xcode Cloud:

- A shared `esc-chatmail` scheme at `esc-chatmail.xcodeproj/xcshareddata/xcschemes/esc-chatmail.xcscheme`
- `ci_scripts/ci_post_clone.sh` to generate `Debug.xcconfig` and `Release.xcconfig` from Xcode Cloud environment variables when you need to override the repository defaults
- `ci_scripts/ci_post_xcodebuild.sh` to generate TestFlight "What to Test" notes from the triggering commit message, changed areas, and matching smoke-test prompts
- `Info.plist` wired to `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` so TestFlight uploads use the target version/build settings instead of hardcoded values

## 1. App Store Connect prerequisites

Before creating the workflow, make sure:

1. The app exists in App Store Connect with bundle identifier `com.esc.inboxchat`.
2. Your Apple Developer team has accepted all current agreements in App Store Connect.
3. Automatic signing works for the `esc-chatmail` target with the intended team and distribution certificates/profiles.

## 2. Optional: add Xcode Cloud environment variables

The repository now includes shared `Debug.xcconfig` and `Release.xcconfig` files, so Xcode Cloud can build without additional configuration.

If you need Xcode Cloud to override those values, `ci_scripts/ci_post_clone.sh` supports these variables:

- `GOOGLE_CLIENT_ID`
- `GOOGLE_API_KEY`
- `GOOGLE_PROJECT_NUMBER`
- `GOOGLE_PROJECT_ID`
- `GOOGLE_REDIRECT_URI`

Add them as Xcode Cloud environment variables and mark the sensitive ones as secret. Use the same values as the checked-in `Debug.xcconfig` and `Release.xcconfig` unless you intentionally want Cloud to build against a different Google project.

## 3. Create the workflow in Xcode

In Xcode:

1. Open the project and create an Xcode Cloud workflow for the shared `esc-chatmail` scheme.
2. Add an `Archive` action.
3. For deployment preparation, choose `TestFlight and App Store`.
4. Add a post-action to distribute the archive to TestFlight.
5. Pick the branch trigger you want, for example your default branch or a release branch.

If you want a faster internal-only lane, create a second workflow that distributes only to internal testers.

## 4. TestFlight behavior to expect

- Xcode Cloud will generate TestFlight "What to Test" text with:
  - the latest commit subject and body under `What Changed`
  - app areas inferred from changed files under `Changed Areas`
  - matching smoke-test prompts under `What to Test`
- Builds produced by Xcode Cloud still need to be added to tester groups in App Store Connect.
- If you already uploaded build `1` for version `1.0`, increment `CURRENT_PROJECT_VERSION` before your first cloud upload to avoid a duplicate build number rejection.

## 5. First verification pass

After saving the workflow:

1. Run a manual build from Xcode Cloud.
2. Confirm the `ci_post_clone.sh` step either used the repository xcconfig files or generated replacements from your environment variables.
3. Confirm the archive uploads to TestFlight successfully.
4. In App Store Connect, add the new build to your internal testing group and verify the generated "What to Test" note.

## References

- Xcode Cloud overview: https://developer.apple.com/documentation/xcode/xcode-cloud
- Setting up your project to use Xcode Cloud: https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud
- Writing custom build scripts: https://developer.apple.com/documentation/xcode/writing-custom-build-scripts
- Sharing environment variables across Xcode Cloud workflows: https://developer.apple.com/documentation/xcode/sharing-environment-variables-across-xcode-cloud-workflows
- Creating a workflow that builds your app for distribution: https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution
- Including notes for testers with a beta release of your app: https://developer.apple.com/documentation/xcode/including-notes-for-testers-with-a-beta-release-of-your-app
- Add internal testers in App Store Connect: https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/
