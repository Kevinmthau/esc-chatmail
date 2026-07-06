#!/usr/bin/env bash
# Boots the iPhone simulator run-tests.sh would pick (or $SIMULATOR_ID if set)
# and pre-grants the TCC permissions the test host app needs. Hosted tests
# reach CNContactStore.requestAccess through ContactsResolver; on a headless
# runner the permission dialog is never answered, so without a pre-grant the
# first test to touch Contacts blocks forever.
#
# Prints exactly one line on stdout — DESTINATION=platform=iOS Simulator,id=<uuid>
# (append it to $GITHUB_ENV in CI); all progress output goes to stderr.
set -euo pipefail

APP_BUNDLE_ID="com.esc.inboxchat"

DEVICE_ID="${SIMULATOR_ID:-}"
if [[ -z "${DEVICE_ID}" ]]; then
  # Same selection as Scripts/run-tests.sh so both pick the same device.
  DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ && $0 !~ /unavailable/ {print $2; exit}')"
fi
if [[ -z "${DEVICE_ID}" ]]; then
  echo "No available iPhone simulator found. Set SIMULATOR_ID or create a simulator." >&2
  exit 1
fi

xcrun simctl bootstatus "${DEVICE_ID}" -b >&2
xcrun simctl privacy "${DEVICE_ID}" grant contacts "${APP_BUNDLE_ID}" >&2

echo "DESTINATION=platform=iOS Simulator,id=${DEVICE_ID}"
