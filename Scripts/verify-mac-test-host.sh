#!/usr/bin/env bash
# Usage: Scripts/verify-mac-test-host.sh <path/to/MushMail.app>
#
# Exits 0 only if the app has a valid code signature that carries the App
# Sandbox entitlement. run-tests.sh calls it before a Mac test run, because a
# hosted Mac test run launches the app itself: outside the sandbox, the app's
# fresh-install and sign-out cleanup would delete the user's real
# ~/Documents/Messages and ~/Documents/Attachments. It never launches the app.
set -euo pipefail

HOST_APP="${1:-}"

refuse() {
  echo "Refusing to run Mac tests: $1" >&2
  echo "Unsandboxed, the test host's cleanup can delete the real ~/Documents/Messages and ~/Documents/Attachments." >&2
  echo "Sign it with the team (pass -allowProvisioningUpdates once to create the Mac profile), never with CODE_SIGNING_ALLOWED=NO." >&2
  exit 1
}

if [[ -z "${HOST_APP}" || "${HOST_APP}" != *.app || ! -d "${HOST_APP}" ]]; then
  refuse "no built test host app at '${HOST_APP}'."
fi

if ! codesign --verify "${HOST_APP}" 2>/dev/null; then
  refuse "${HOST_APP} has no valid code signature."
fi

ENTITLEMENTS="$(codesign -d --entitlements - --xml "${HOST_APP}" 2>/dev/null || true)"
if ! printf '%s' "${ENTITLEMENTS}" | python3 -I -c '
import plistlib, sys
data = sys.stdin.buffer.read()
entitlements = plistlib.loads(data) if data.strip() else {}
sys.exit(0 if entitlements.get("com.apple.security.app-sandbox") is True else 1)
'; then
  refuse "${HOST_APP} is not signed with the App Sandbox entitlement."
fi
