# TestFlight Automation

This repository is configured to create a TestFlight build on every push to `main`.

The workflow lives in `.github/workflows/ci.yml`:

- Pull requests run unit tests only.
- Pushes to `main` run unit tests first, then archive and upload a signed release build to TestFlight.
- `workflow_dispatch` is enabled so you can rerun the release flow manually from GitHub Actions.

## GitHub Secrets

Create these repository or organization secrets before expecting the TestFlight job to succeed:

- `APP_STORE_CONNECT_ISSUER_ID`: App Store Connect API issuer ID.
- `APP_STORE_CONNECT_KEY_ID`: App Store Connect API key ID.
- `APP_STORE_CONNECT_API_KEY`: Contents of the downloaded `.p8` App Store Connect API key.

For app configuration, choose one of these approaches:

- Recommended: `CI_XCCONFIG`
  Paste the full xcconfig contents used for both `Debug.xcconfig` and `Release.xcconfig`.
- Optional override: `DEBUG_XCCONFIG`
  Use this if your debug config should differ from release.
- Optional override: `RELEASE_XCCONFIG`
  Use this if your release config should differ from debug.

If none of the xcconfig secrets are set, pull request test jobs fall back to placeholder values so the project can still compile in CI. The TestFlight job requires a real release xcconfig secret.

## One-Time Apple Setup

1. In App Store Connect, enable API access for your team if it is not already enabled.
2. Generate an App Store Connect API key and save the `.p8` file immediately. Apple only lets you download it once.
3. Confirm the `com.esc.inboxchat` App ID and App Store provisioning profile exist for team `3JXY2MS2Y3`.
4. Ensure the API key has enough access for cloud signing and TestFlight upload. If cloud signing is restricted on your team, an Account Holder or Admin may need to grant access or perform the first signing setup.

## Secret Preparation Commands

If you want to use one shared xcconfig secret, copy the full file contents to your clipboard:

```bash
pbcopy < esc-chatmail/Configuration/Release.xcconfig
```

If your debug and release configs differ, create separate `DEBUG_XCCONFIG` and `RELEASE_XCCONFIG` secrets instead.

## What The Workflow Does

1. Writes CI xcconfig files into `esc-chatmail/Configuration/`.
2. Runs `bash Scripts/run-tests.sh -skip-testing esc-chatmailUITests`.
3. Downloads the App Store provisioning profile for `com.esc.inboxchat`.
4. Archives the app with a UTC timestamp build number.
5. Uses Xcode automatic signing plus the App Store Connect API key for cloud signing during export.
6. Exports a signed `.ipa`.
7. Uploads that `.ipa` to TestFlight.

## Notes

- The build number is generated from UTC time in `YYYYMMDDHHMMSS` format to avoid duplicate TestFlight uploads.
- `CFBundleShortVersionString` and `CFBundleVersion` now resolve from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, so CI can inject a unique build number without editing tracked files.
- This setup intentionally avoids storing a distribution `.p12` in GitHub. It relies on Xcode cloud signing via `-allowProvisioningUpdates` and App Store Connect API key authentication.
- If the release job fails immediately with a missing-secret message, finish the GitHub secret setup first.
