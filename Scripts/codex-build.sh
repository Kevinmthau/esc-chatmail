#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: ./Scripts/codex-build.sh [--for-testing] [xcodebuild args...]

  --for-testing   Also compile the test target (xcodebuild build-for-testing).
                  It runs no tests. Debug only: the test target needs seams that
                  exist only in DEBUG.

Environment:
  CONFIGURATION   Debug (default) or Release. Release is what Xcode Cloud archives;
                  CI compiles it so a Release-only error or warning on CI's toolchain
                  fails a PR, not the archive after the merge.

Examples:
  ./Scripts/codex-build.sh
  DESTINATION='platform=macOS' ./Scripts/codex-build.sh CODE_SIGNING_ALLOWED=NO   # compile check; never launch it
  DESTINATION='platform=macOS' ./Scripts/codex-build.sh --for-testing CODE_SIGNING_ALLOWED=NO   # app and tests, compile check only; CI runs the Mac plan through codex-test.sh --ci-mac-host
  CONFIGURATION=Release DESTINATION='generic/platform=iOS Simulator' ./Scripts/codex-build.sh CODE_SIGNING_ALLOWED=NO
USAGE
  exit 0
fi

ACTION="build"
if [[ "${1:-}" == "--for-testing" ]]; then
  ACTION="build-for-testing"
  shift
fi

# Set here and never passed as an argument too: a second -configuration on the command
# line is not a reliable override.
CONFIGURATION="${CONFIGURATION:-Debug}"
case "${CONFIGURATION}" in
  Debug|Release) ;;
  *)
    echo "error: CONFIGURATION must be Debug or Release, not '${CONFIGURATION}'" >&2
    exit 2
    ;;
esac
if [[ "${ACTION}" == "build-for-testing" && "${CONFIGURATION}" != "Debug" ]]; then
  echo "error: --for-testing builds Debug only; the test target needs DEBUG-only seams" >&2
  exit 2
fi

DESTINATION="${DESTINATION:-$(python3 "${SCRIPT_DIR}/default-simulator-destination.py")}"
export DESTINATION

cd "${REPO_ROOT}"
exec xcodebuild "${ACTION}" \
  -project esc-chatmail.xcodeproj \
  -scheme esc-chatmail \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  "$@"
