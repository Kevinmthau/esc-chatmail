#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: ./Scripts/codex-build.sh [--for-testing] [xcodebuild args...]

  --for-testing   Also compile the test target (xcodebuild build-for-testing).
                  It runs no tests.

Examples:
  ./Scripts/codex-build.sh
  DESTINATION='platform=macOS' ./Scripts/codex-build.sh CODE_SIGNING_ALLOWED=NO   # compile check; never launch it
  DESTINATION='platform=macOS' ./Scripts/codex-build.sh --for-testing CODE_SIGNING_ALLOWED=NO   # app and tests, as CI does
USAGE
  exit 0
fi

ACTION="build"
if [[ "${1:-}" == "--for-testing" ]]; then
  ACTION="build-for-testing"
  shift
fi

DESTINATION="${DESTINATION:-$(python3 "${SCRIPT_DIR}/default-simulator-destination.py")}"
export DESTINATION

cd "${REPO_ROOT}"
exec xcodebuild "${ACTION}" \
  -project esc-chatmail.xcodeproj \
  -scheme esc-chatmail \
  -configuration Debug \
  -destination "${DESTINATION}" \
  "$@"
