#!/bin/zsh
set -euo pipefail

# Xcode Cloud pre-build hook: run SwiftLint in ADVISORY mode.
#
# Lint violations are surfaced as warnings in the Xcode Cloud build log but never fail
# the build. SwiftLint is pinned for reproducible runs, with a Homebrew fallback.

script_dir="${0:A:h}"
repo_root="${script_dir:h}"

# Pin the SwiftLint version so rule changes don't silently drift between Cloud runs.
SWIFTLINT_VERSION="${SWIFTLINT_VERSION:-0.63.3}"

if ! command -v swiftlint >/dev/null 2>&1; then
  print "Installing SwiftLint ${SWIFTLINT_VERSION} for Xcode Cloud..."
  tmp_dir="$(mktemp -d)"
  download_url="https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/portable_swiftlint.zip"
  if curl -fsSL "${download_url}" -o "${tmp_dir}/swiftlint.zip" \
     && unzip -q "${tmp_dir}/swiftlint.zip" -d "${tmp_dir}"; then
    export PATH="${tmp_dir}:${PATH}"
  elif command -v brew >/dev/null 2>&1; then
    print "Pinned download failed; falling back to Homebrew."
    brew install swiftlint || true
  fi
fi

if command -v swiftlint >/dev/null 2>&1; then
  print "Running SwiftLint (advisory)..."
  "${repo_root}/Scripts/lint.sh" || true
else
  print "warning: SwiftLint unavailable — skipping advisory lint."
fi

# Advisory hook: never block the build.
exit 0
