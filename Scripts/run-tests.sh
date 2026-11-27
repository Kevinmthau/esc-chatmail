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

# The platform is read from DESTINATION alone: it picks the test plan and, on
# the Mac, the sandbox check below. So DESTINATION must name its platform (in
# any letter case). One that names none, such as a bare id=..., could be the
# Mac, and is refused rather than run as an iOS destination: the full plan in
# a Mac test host, with no check.
DESTINATION_LOWERCASED="$(printf '%s' "${DESTINATION}" | tr '[:upper:]' '[:lower:]')"
case "${DESTINATION_LOWERCASED}" in
  *"platform=macos"* | *"platform=os x"*)
    IS_MAC_DESTINATION=true
    ;;
  *"platform=ios"*)
    IS_MAC_DESTINATION=false
    ;;
  *)
    echo "DESTINATION must name its platform, for example 'platform=iOS Simulator,id=<udid>' or 'platform=macOS'. Got: ${DESTINATION}" >&2
    exit 1
    ;;
esac

ARGS=()
RUN_PERFORMANCE_TESTS=false
USE_CI_MAC_HOST=false
RUN_CONCURRENCY_DEBUG=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --performance)
      RUN_PERFORMANCE_TESTS=true
      shift
      ;;
    --ci-mac-host)
      USE_CI_MAC_HOST=true
      shift
      ;;
    --concurrency-debug)
      RUN_CONCURRENCY_DEBUG=true
      shift
      ;;
    -destination)
      # xcodebuild runs every destination it is given, so a second one here
      # would get the plan picked for DESTINATION. Were it the Mac, that is
      # the full iOS plan in a Mac test host with no sandbox check.
      echo "Set DESTINATION instead of passing -destination: the test plan and the Mac sandbox check follow DESTINATION." >&2
      exit 1
      ;;
    -testPlan)
      # Same hole from the other side: -testPlan esc-chatmail with a Mac
      # DESTINATION is the full iOS plan in a Mac test host.
      echo "The test plan follows DESTINATION (and --performance or --concurrency-debug); -testPlan cannot be passed." >&2
      exit 1
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "${USE_CI_MAC_HOST}" == "true" && "${IS_MAC_DESTINATION}" != "true" ]]; then
  echo "--ci-mac-host signs the Mac test host for CI; it has no meaning for an iOS destination." >&2
  exit 1
fi

if [[ "${RUN_CONCURRENCY_DEBUG}" == "true" ]]; then
  if [[ "${IS_MAC_DESTINATION}" == "true" || "${RUN_PERFORMANCE_TESTS}" == "true" ]]; then
    echo "--concurrency-debug runs ConcurrencyDebug.xctestplan on the iOS simulator and cannot be combined with --performance." >&2
    exit 1
  fi
  # ConcurrencyDebug test plan: the suites measured clean under Core Data's
  # -com.apple.CoreData.ConcurrencyDebug 1, which the plan passes to the host
  # and which traps on a context touched off its queue (architecture review
  # 2026-11, testing-ci-release#4). Serial, so a crash names its host; the
  # default plan cannot carry the flag, because its private-queue test contexts
  # are touched off-queue by design. Adding a suite is in CLAUDE.md (Testing).
  ARGS+=("-testPlan" "ConcurrencyDebug" "-parallel-testing-enabled" "NO")
elif [[ "${RUN_PERFORMANCE_TESTS}" == "true" ]]; then
  if [[ "${IS_MAC_DESTINATION}" == "true" ]]; then
    echo "The performance test plan runs on the iOS simulator only." >&2
    exit 1
  fi
  # Performance test plan: PerformanceRegressionTests and the scale harness
  # (ScaleQueryPlanTests, ScaleHubFaultTests), which seeds a 120k-message store.
  ARGS+=("-testPlan" "Performance")
elif [[ "${IS_MAC_DESTINATION}" == "true" ]]; then
  # Mac test plan: the suites that show Services/ behaves the same on macOS
  # (docs/mac-app-plan.md, PR F). The full suite stays on iOS.
  ARGS+=("-testPlan" "Mac")
else
  # Default test plan: runs the suite without the Performance plan's suites.
  # PerformanceRegressionTests are timing-sensitive, and the scale harness
  # takes about half a minute to seed its store.
  ARGS+=("-testPlan" "esc-chatmail")
fi

if [[ "${IS_MAC_DESTINATION}" != "true" ]]; then
  exec xcodebuild test \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "${DESTINATION}" \
    "${ARGS[@]}"
fi

# --ci-mac-host: the Mac test host signed for CI (architecture review 2026-11,
# mac-platform#1, testing-ci-release#3). CI has no Mac development profile,
# which the team's signature needs for keychain-access-groups, and an unsigned
# host has no sandbox and is refused below. Scripts/CI-MacTestHost.xcconfig
# signs the host ad hoc with entitlements that keep the App Sandbox and drop the
# keychain group, under a .ci bundle ID (a container of its own, never the
# installed MushMail's), so both sandbox checks admit it unchanged. With no
# keychain group the data protection keychain refuses the host's items (-34018),
# so KeychainServiceTests, the one Mac-plan suite that writes the real keychain,
# is skipped here and nowhere else; every other suite injects its keychain. The
# xcconfig goes to the build, the host lookup and the test run alike, through
# the ARGS split below, so the host checked is the host launched.
if [[ "${USE_CI_MAC_HOST}" == "true" ]]; then
  ARGS+=("-xcconfig" "Scripts/CI-MacTestHost.xcconfig")
  ARGS+=("-skip-testing:esc-chatmailTests/KeychainServiceTests")
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
#
# The host lookup below must resolve the same product the build writes and the
# test run launches, so it gets every argument that decides where products go:
# build settings (NAME=value) and the options in the second case. Without
# -configuration, for one, the lookup named the Debug host while the tests
# launched the Release one, and a stale signed Debug host passed the check for
# an unsigned Release build. The app checks itself as well
# (MacUnitTestHostGuard), so a lookup that is still wrong cannot run tests
# outside the sandbox.
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
    -derivedDataPath | -configuration | -xcconfig | -sdk | -arch | -toolchain | -scheme | -project | -workspace)
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

# What CI signed, for its log: the identifier (with its .ci suffix), the ad-hoc
# signature (no team) and the entitlements the sandbox check just read.
if [[ "${USE_CI_MAC_HOST}" == "true" ]]; then
  HOST_APP="${TEST_HOST%/Contents/MacOS/*}"
  echo "CI Mac test host: ${HOST_APP}" >&2
  codesign -dvv "${HOST_APP}" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Signature|Authority)' >&2 || true
  codesign -d --entitlements - --xml "${HOST_APP}" 2>/dev/null | plutil -p - >&2 || true
fi

exec xcodebuild test-without-building \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  "${ARGS[@]}"
