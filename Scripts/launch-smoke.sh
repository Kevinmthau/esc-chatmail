#!/usr/bin/env bash
# Launches a built iOS app on an erased simulator and checks that the real launch path ran
# (architecture review 2026-11, testing-ci-release#2, part 2):
#
#   Scripts/launch-smoke.sh <path/to/esc-chatmail.app> [simulator udid]
#
# - The process is still alive after LAUNCH_SMOKE_WAIT_SECONDS (default 20).
# - No crash report for it was written meanwhile (~/Library/Logs/DiagnosticReports).
# - The app published the sign-in root: ContentView records the root screen's
#   accessibility identifier in the unified log (LaunchRootScreenRecord, subsystem = the
#   bundle ID, category "launch"), and a fresh install with no session shows SignInView.
# - The store was created in the app's data container (the launch reached the Core Data
#   bootstrap).
#
# CI runs it on the Release build after check-built-info-plist.sh: Release is what Xcode
# Cloud archives, and before this the first launch of a Release build was the TestFlight
# install after the merge. It is no test plan and no part of run-tests.sh.
#
# The simulator is erased, so it must be a device of this run's own, never the one another
# run is using: the device is the second argument, else SIMULATOR_ID, else the id in
# DESTINATION (the wrappers' variables, so a developer's pinned device is honoured), and only
# in CI (GITHUB_ACTIONS) the picker's default iPhone 17 Pro, whose job has it to itself.
# Outside CI with none of those the script refuses: that default is the device
# codex-test.sh resolves in another shell, and erasing it drops its Contacts grant, after
# which that shell's next Contacts-touching test hangs (PR 501 review).
#
# The sign-in root is awaited, not sampled once: the process must be alive WAIT_SECONDS
# after launch (default 20), and the root line is looked for until DEADLINE_SECONDS after
# launch (default 90), because this step fails the job ship-gate needs and a cold Release
# launch on a loaded runner is not timed. Nothing here reads mail or signs in: the app
# starts signed out, as a fresh install does.
set -euo pipefail

APP="${1:-}"
if [[ -z "${APP}" || "${APP}" != *.app || ! -d "${APP}" ]]; then
  echo "usage: $0 <path/to/App.app> [simulator udid]" >&2
  exit 2
fi
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "${APP}/Info.plist")"
EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "${APP}/Info.plist")"
# The device (see the header). The picker prints a `platform=iOS Simulator,id=<udid>` line
# and nothing else (it is not asked for a bare UDID), so the id is read out of that line, as
# it is out of DESTINATION. Whatever the source, the result is checked for the shape of a
# UDID before anything is erased, so a wrong value fails here, naming itself, not in simctl.
DEVICE_SOURCE=""
if [[ -n "${2:-}" ]]; then
  UDID="$2"
  DEVICE_SOURCE="the second argument"
elif [[ -n "${SIMULATOR_ID:-}" ]]; then
  UDID="${SIMULATOR_ID}"
  DEVICE_SOURCE="SIMULATOR_ID"
elif [[ -n "${DESTINATION:-}" ]]; then
  UDID="${DESTINATION##*id=}"
  DEVICE_SOURCE="DESTINATION '${DESTINATION}'"
elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  DESTINATION_LINE="$(python3 "$(dirname "${BASH_SOURCE[0]}")/default-simulator-destination.py")"
  UDID="${DESTINATION_LINE##*id=}"
  DEVICE_SOURCE="the picker's '${DESTINATION_LINE}'"
else
  echo "error: no device. Pass the UDID of a simulator of your own as the second argument, or set SIMULATOR_ID or DESTINATION to one; this script erases the device, so it never takes the wrappers' default outside CI." >&2
  exit 2
fi
if ! [[ "${UDID}" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]]; then
  echo "error: no simulator UDID to erase (got '${UDID}' from ${DEVICE_SOURCE})" >&2
  exit 2
fi
WAIT_SECONDS="${LAUNCH_SMOKE_WAIT_SECONDS:-20}"
DEADLINE_SECONDS="${LAUNCH_SMOKE_DEADLINE_SECONDS:-90}"
# The identifier ContentView gives the sign-in root and the line that records it
# (LaunchRootScreen.signIn, LaunchRootScreenRecord); LaunchSmokeSourceTests pins the match.
EXPECTED_LINE="Root screen published: launch.root.signIn"
REPORTS_DIR="${HOME}/Library/Logs/DiagnosticReports"

failures=0
fail() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}

cleanup() {
  xcrun simctl terminate "${UDID}" "${BUNDLE_ID}" >/dev/null 2>&1 || true
  xcrun simctl shutdown "${UDID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Launch smoke: ${APP} (${BUNDLE_ID}) on ${UDID}" >&2
xcrun simctl shutdown "${UDID}" >/dev/null 2>&1 || true
xcrun simctl erase "${UDID}"
xcrun simctl bootstatus "${UDID}" -b >&2
xcrun simctl install "${UDID}" "${APP}"

# Everything after this moment is the launch's: the log window and the crash reports.
mkdir -p "${REPORTS_DIR}"
MARKER="$(mktemp "${TMPDIR:-/tmp}/launch-smoke.XXXXXX")"
START="$(date '+%Y-%m-%d %H:%M:%S')"
LAUNCHED="$(xcrun simctl launch "${UDID}" "${BUNDLE_ID}")"
echo "${LAUNCHED}" >&2
PID="${LAUNCHED##*: }"
if ! [[ "${PID}" =~ ^[0-9]+$ ]]; then
  echo "error: simctl launch printed no pid: ${LAUNCHED}" >&2
  exit 1
fi

sleep "${WAIT_SECONDS}"

# 1. Alive, and still our process (a pid can be reused once the app has gone).
if kill -0 "${PID}" 2>/dev/null && ps -o comm= -p "${PID}" | grep -q "/${EXECUTABLE}\$"; then
  echo "alive after ${WAIT_SECONDS}s: pid ${PID}" >&2
else
  fail "${BUNDLE_ID} (pid ${PID}) is not running ${WAIT_SECONDS}s after launch"
fi

# 2. No crash report since the launch.
NEW_REPORTS="$(find "${REPORTS_DIR}" -maxdepth 1 -name "${EXECUTABLE}*.ips" -newer "${MARKER}" 2>/dev/null || true)"
if [[ -n "${NEW_REPORTS}" ]]; then
  fail "crash report(s) written since the launch:"
  echo "${NEW_REPORTS}" >&2
fi
rm -f "${MARKER}"

# 3. The sign-in root was published (the whole launch path ran to ContentView): looked for
#    until the deadline, so a slow cold launch is a late pass, not a failed job.
launch_log() {
  xcrun simctl spawn "${UDID}" log show --style compact --start "${START}" \
    --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"launch\"" 2>/dev/null || true
}
LAUNCH_LOG="$(launch_log)"
ELAPSED="${WAIT_SECONDS}"
while ! printf '%s\n' "${LAUNCH_LOG}" | grep -qF "${EXPECTED_LINE}" && [[ "${ELAPSED}" -lt "${DEADLINE_SECONDS}" ]]; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  LAUNCH_LOG="$(launch_log)"
done
if printf '%s\n' "${LAUNCH_LOG}" | grep -qF "${EXPECTED_LINE}"; then
  echo "root screen: ${EXPECTED_LINE} (within ${ELAPSED}s)" >&2
else
  fail "no '${EXPECTED_LINE}' in the launch log within ${DEADLINE_SECONDS}s of the launch:"
  printf '%s\n' "${LAUNCH_LOG}" | tail -20 >&2
fi

# 4. The store exists where NSPersistentContainer puts it.
DATA_CONTAINER="$(xcrun simctl get_app_container "${UDID}" "${BUNDLE_ID}" data)"
STORE="${DATA_CONTAINER}/Library/Application Support/ESCChatmail.sqlite"
if [[ -f "${STORE}" ]]; then
  echo "store: ${STORE}" >&2
else
  fail "no store at ${STORE}"
  ls -la "${DATA_CONTAINER}/Library/Application Support" >&2 2>/dev/null || true
fi

if [[ ${failures} -gt 0 ]]; then
  echo "Launch smoke failed (${failures})." >&2
  exit 1
fi
echo "Launch smoke passed: ${BUNDLE_ID} launched signed out on ${UDID}, alive after ${WAIT_SECONDS}s, no crash report, sign-in root published, store created."
