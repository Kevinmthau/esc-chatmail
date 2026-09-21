#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: ./Scripts/codex-build.sh [xcodebuild args...]

Example:
  ./Scripts/codex-build.sh
USAGE
  exit 0
fi

DESTINATION="${DESTINATION:-$(python3 "${SCRIPT_DIR}/default-simulator-destination.py")}"
export DESTINATION

cd "${REPO_ROOT}"
exec xcodebuild build \
  -project esc-chatmail.xcodeproj \
  -scheme esc-chatmail \
  -configuration Debug \
  -destination "${DESTINATION}" \
  "$@"
