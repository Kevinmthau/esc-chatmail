#!/usr/bin/env bash
set -euo pipefail

SCHEME="esc-chatmail"
CONFIGURATION="Debug"

DESTINATION="${DESTINATION:-}"
if [[ -z "${DESTINATION}" ]]; then
  DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && $0 !~ /unavailable/ {print $2; exit}')"
  if [[ -z "${DEVICE_ID}" ]]; then
    echo "No available iPhone simulator found. Set DESTINATION or create a simulator." >&2
    exit 1
  fi
  DESTINATION="platform=iOS Simulator,id=${DEVICE_ID}"
fi

IS_MAC_DESTINATION=false
if [[ "${DESTINATION}" == *"platform=macOS"* ]]; then
  IS_MAC_DESTINATION=true
fi

ARGS=()
RUN_PERFORMANCE_TESTS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --performance)
      RUN_PERFORMANCE_TESTS=true
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "${RUN_PERFORMANCE_TESTS}" == "true" ]]; then
  if [[ "${IS_MAC_DESTINATION}" == "true" ]]; then
    echo "The performance test plan runs on the iOS simulator only." >&2
    exit 1
  fi
  # Performance test plan: runs only PerformanceRegressionTests.
  ARGS+=("-testPlan" "Performance")
elif [[ "${IS_MAC_DESTINATION}" == "true" ]]; then
  # Mac test plan: the suites that show Services/ behaves the same on macOS
  # (docs/mac-app-plan.md, PR F). The full suite stays on iOS.
  ARGS+=("-testPlan" "Mac")
else
  # Default test plan: runs the suite with PerformanceRegressionTests excluded
  # because they are timing-sensitive.
  ARGS+=("-testPlan" "esc-chatmail")
fi

if [[ "${IS_MAC_DESTINATION}" != "true" ]]; then
  exec xcodebuild test \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" \
    "${ARGS[@]}"
fi

# macOS: a hosted test run launches the app itself as the test host. Outside the
# App Sandbox, the app's fresh-install and sign-out cleanup would delete the
# user's real ~/Documents/Messages and ~/Documents/Attachments, so build first
# and run the tests only if the host's signature carries the sandbox
# entitlement. An unsigned build (CODE_SIGNING_ALLOWED=NO) carries none and is
# refused here; sign with the team instead (pass -allowProvisioningUpdates the
# first time, so Xcode can create the Mac development profile).

# Everything but the result bundle goes to the build too: a build that wrote
# the bundle would make the test run fail on an existing path.
BUILD_ARGS=()
SETTINGS_ARGS=()
i=0
while [[ ${i} -lt ${#ARGS[@]} ]]; do
  arg="${ARGS[${i}]}"
  case "${arg}" in
    -resultBundlePath)
      i=$((i + 2))
      continue
      ;;
    -derivedDataPath)
      BUILD_ARGS+=("${arg}" "${ARGS[$((i + 1))]}")
      SETTINGS_ARGS+=("${arg}" "${ARGS[$((i + 1))]}")
      i=$((i + 2))
      continue
      ;;
  esac
  BUILD_ARGS+=("${arg}")
  if [[ "${arg}" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?= ]]; then
    SETTINGS_ARGS+=("${arg}")
  fi
  i=$((i + 1))
done

xcodebuild build-for-testing \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  "${BUILD_ARGS[@]}"

# The test action's settings include the test target, whose TEST_HOST is the
# app that will launch; the plain -showBuildSettings lists only the app target.
TEST_HOST="$(
  xcodebuild test -showBuildSettings -json \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" \
    ${SETTINGS_ARGS[@]+"${SETTINGS_ARGS[@]}"} 2>/dev/null \
  | python3 -I -c '
import json, sys
for entry in json.load(sys.stdin):
    if entry.get("target") == "esc-chatmailTests":
        print(entry["buildSettings"]["TEST_HOST"])
        break
'
)"
bash "$(dirname "${BASH_SOURCE[0]}")/verify-mac-test-host.sh" "${TEST_HOST%/Contents/MacOS/*}"

exec xcodebuild test-without-building \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  "${ARGS[@]}"
