# Xcode Cloud Setup

This repository now includes the project-side requirements to build and distribute `esc-chatmail` with Xcode Cloud:

- A shared `esc-chatmail` scheme at `esc-chatmail.xcodeproj/xcshareddata/xcschemes/esc-chatmail.xcscheme`
- `esc-chatmail.xctestplan` (default test plan; excludes the timing-sensitive performance tests) and `Performance.xctestplan` (performance tests only), both referenced by the shared scheme
- `ci_scripts/ci_post_clone.sh` to generate `Debug.xcconfig` and `Release.xcconfig` from Xcode Cloud environment variables when you need to override the repository defaults
- `ci_scripts/ci_post_xcodebuild.sh` to generate TestFlight "What to Test" notes from the triggering commit message, changed areas, and matching smoke-test prompts
- `ci_scripts/ci_pre_xcodebuild.sh` to run SwiftLint in advisory mode (warnings only) before each build
- `Scripts/xcode-cloud-api.sh` to create and start Xcode Cloud workflows through the App Store Connect API once the Apple-side Xcode Cloud product exists
- `.swiftlint.yml` and `Scripts/lint.sh` for advisory linting locally and in CI
- `Info.plist` wired to `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` so TestFlight uploads use the target version/build settings instead of hardcoded values

For running the test suite and SwiftLint in CI, see [Running tests in Xcode Cloud](#running-tests-in-xcode-cloud) and [SwiftLint (advisory)](#swiftlint-advisory) below.

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

## 3. Create workflows from the CLI

`Scripts/xcode-cloud-api.sh` can create the default Xcode Cloud workflows through the App Store Connect API:

- `PR Tests`: runs the shared scheme's default `esc-chatmail` test plan for pull requests targeting `main`
- `main TestFlight`: archives `main` for TestFlight and App Store-eligible distribution

Apple-side boundary: the API creates workflows for an existing Xcode Cloud product. If the app has never been connected to Xcode Cloud, first use Xcode or App Store Connect once to grant repository access and create/detect the Xcode Cloud product. After that, the workflow setup can run from the CLI.

Verify the local product that Xcode Cloud should detect:

```bash
./Scripts/xcode-cloud-api.sh describe-local-product
```

Authenticate with an App Store Connect API key:

```bash
export ASC_KEY_ID='<key-id>'
export ASC_ISSUER_ID='<issuer-id>'
export ASC_PRIVATE_KEY_PATH="$HOME/secure/AuthKey_<key-id>.p8"
```

Find the product, repository, Xcode version, and macOS version IDs:

```bash
./Scripts/xcode-cloud-api.sh list-products
./Scripts/xcode-cloud-api.sh list-versions
```

Then export the IDs you want the workflow to use:

```bash
export ASC_CI_PRODUCT_ID='<ciProducts-id>'
export ASC_CI_REPOSITORY_ID='<scmRepositories-id>'
export ASC_CI_XCODE_VERSION_ID='<ciXcodeVersions-id>'
export ASC_CI_MACOS_VERSION_ID='<ciMacOsVersions-id>'
export ASC_BRANCH='main'
```

The PR test workflow defaults to Xcode Cloud's `iPhone 17 Pro` simulator on `iOS 26.5`. If you choose a different Xcode version, list its `testDestinations` with `./Scripts/xcode-cloud-api.sh list-versions` and override these values when needed:

```bash
export ASC_TEST_DEVICE_NAME='iPhone 17 Pro'
export ASC_TEST_DEVICE_ID='com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'
export ASC_TEST_RUNTIME_NAME='iOS 26.5'
export ASC_TEST_RUNTIME_ID='com.apple.CoreSimulator.SimRuntime.iOS-26-5'
```

Preview the JSON payloads before creating anything:

```bash
./Scripts/xcode-cloud-api.sh print-pr-test-workflow-payload
./Scripts/xcode-cloud-api.sh print-testflight-workflow-payload
```

Create both default workflows:

```bash
./Scripts/xcode-cloud-api.sh create-default-workflows
```

To trigger a manual build later, list Git references and start the workflow:

```bash
./Scripts/xcode-cloud-api.sh list-git-references "$ASC_CI_REPOSITORY_ID"
./Scripts/xcode-cloud-api.sh start-build '<ciWorkflows-id>' '<scmGitReferences-id>'
```

If `list-products` does not return an `esc-chatmail` product for bundle identifier `com.esc.inboxchat`, complete the first Xcode Cloud setup/grant in Xcode or App Store Connect, then rerun the CLI commands.

## 4. Alternative: create the workflow in Xcode

In Xcode:

1. Open the project and create an Xcode Cloud workflow for the shared `esc-chatmail` scheme.
2. Add an `Archive` action.
3. For deployment preparation, choose `TestFlight and App Store`.
4. Add a post-action to distribute the archive to TestFlight.
5. Pick the branch trigger you want, for example your default branch or a release branch.

If you want a faster internal-only lane, create a second workflow that distributes only to internal testers.

## 5. TestFlight behavior to expect

- Xcode Cloud will generate TestFlight "What to Test" text with:
  - the latest commit subject and body under `What Changed`
  - app areas inferred from changed files under `Changed Areas`
  - matching smoke-test prompts under `What to Test`
  - truncated details when needed to stay within App Store Connect's 4000-character note limit
- Builds produced by Xcode Cloud still need to be added to tester groups in App Store Connect.
- If you already uploaded build `1` for version `1.0`, increment `CURRENT_PROJECT_VERSION` before your first cloud upload to avoid a duplicate build number rejection.

## 6. First verification pass

After creating or saving the workflows:

1. Run a manual build from Xcode Cloud.
2. Confirm the `ci_post_clone.sh` step either used the repository xcconfig files or generated replacements from your environment variables.
3. Confirm the archive uploads to TestFlight successfully.
4. In App Store Connect, add the new build to your internal testing group and verify the generated "What to Test" note.

## Running tests in Xcode Cloud

The shared `esc-chatmail` scheme's Test action already runs the `esc-chatmailTests` target, so a test workflow needs no scheme changes.

To add PR-gating test runs manually:

1. In Xcode (or App Store Connect), create a second Xcode Cloud workflow on the shared `esc-chatmail` scheme.
2. Add a **Test** action (Debug configuration, an iOS Simulator destination such as iPhone 17 Pro). Use the default `esc-chatmail` test plan so the performance tests are excluded.
3. Set the start condition to **Pull Request Changes** (and/or branch changes) so the test suite gates merges.
4. Save. Subsequent pull requests run the suite automatically.

If you used `./Scripts/xcode-cloud-api.sh create-default-workflows`, the `PR Tests` workflow already covers this path.

Notes:

- `PerformanceRegressionTests` is excluded from the default `esc-chatmail` test plan, so the Cloud Test action skips the timing-sensitive performance tests automatically. Run them locally with `./Scripts/run-tests.sh --performance`, which selects the dedicated `Performance` test plan. (Test selection lives in the test plans because environment variables set on the host — e.g. `CI` — do not reach the test process running in the simulator.)
- `ci_scripts/ci_post_xcodebuild.sh` (TestFlight notes) exits early unless a signed app is produced, so it is a no-op for Test actions — no extra configuration needed.
- `ci_scripts/ci_post_clone.sh` still generates the xcconfig files, so test builds get the same configuration as archive builds.

## SwiftLint (advisory)

SwiftLint runs in **advisory** mode: it reports violations as warnings but never fails a build or a CI run (no rule is configured with `error` severity).

- Configuration: `.swiftlint.yml` (repo root). Limits are intentionally loose for this first adoption pass; tighten over time.
- Local: `brew install swiftlint`, then `./Scripts/lint.sh`.
- Xcode Cloud: `ci_scripts/ci_pre_xcodebuild.sh` installs a pinned SwiftLint and runs `Scripts/lint.sh` before each build, logging warnings without failing the build.

### Optional: inline SwiftLint warnings in Xcode

To see SwiftLint warnings inline in Xcode's issue navigator, add a Run Script build phase. This is the only change that would touch `project.pbxproj`, so it is left as a deliberate manual step (do it once through the Xcode UI rather than hand-editing the project file):

1. Select the `esc-chatmail` target → **Build Phases**.
2. Click **+ → New Run Script Phase**, then drag it to run **before** "Compile Sources".
3. Name it "SwiftLint (advisory)" and paste:

   ```sh
   if which swiftlint >/dev/null; then
     swiftlint lint --config "$SRCROOT/.swiftlint.yml" || true
   else
     echo "warning: SwiftLint not installed — brew install swiftlint"
   fi
   ```

4. Uncheck **Based on dependency analysis** so it runs on every build.

Because no rule is configured as an error, this phase only ever emits warnings.

## References

- Xcode Cloud overview: https://developer.apple.com/documentation/xcode/xcode-cloud
- Setting up your project to use Xcode Cloud: https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud
- Xcode Cloud Workflows and Builds API: https://developer.apple.com/documentation/appstoreconnectapi/xcode-cloud-workflows-and-builds
- Xcode Cloud Products API: https://developer.apple.com/documentation/appstoreconnectapi/products
- Xcode Cloud Workflows API: https://developer.apple.com/documentation/appstoreconnectapi/workflows
- Writing custom build scripts: https://developer.apple.com/documentation/xcode/writing-custom-build-scripts
- Sharing environment variables across Xcode Cloud workflows: https://developer.apple.com/documentation/xcode/sharing-environment-variables-across-xcode-cloud-workflows
- Creating a workflow that builds your app for distribution: https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution
- Including notes for testers with a beta release of your app: https://developer.apple.com/documentation/xcode/including-notes-for-testers-with-a-beta-release-of-your-app
- Add internal testers in App Store Connect: https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/
