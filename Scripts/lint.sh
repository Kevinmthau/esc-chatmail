#!/usr/bin/env bash
set -euo pipefail

# Advisory SwiftLint runner. Surfaces violations as warnings and never fails the
# caller — used by both local developers and the Xcode Cloud pre-build hook
# (ci_scripts/ci_pre_xcodebuild.sh).
#
# Usage: ./Scripts/lint.sh [extra swiftlint args...]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${REPO_ROOT}/.swiftlint.yml"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "warning: SwiftLint not installed — skipping lint. Install with: brew install swiftlint" >&2
  exit 0
fi

cd "${REPO_ROOT}"

# `|| true` keeps lint advisory: violations are reported but never fail the shell.
swiftlint lint --config "${CONFIG}" --quiet "$@" || true
