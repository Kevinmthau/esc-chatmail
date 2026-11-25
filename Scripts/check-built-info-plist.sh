#!/usr/bin/env bash
# Checks the Info.plist of a built app before it can ship (architecture review 2026-11,
# testing-ci-release#2).
#
#   Scripts/check-built-info-plist.sh <path/to/App.app> <source Info.plist>
#
# - Every GOOGLE_* key the app requires (Constants.swift `requiredConfig`) is present,
#   non-empty and resolved: a Release build whose xcconfig lost a value does not trap the
#   way Debug does; it logs and returns "", and sign-in fails on the user's device.
# - BGTaskSchedulerPermittedIdentifiers, where the source plist has it, is carried into
#   the built plist unchanged: BGTaskScheduler raises on a handler whose identifier is
#   missing.
# - No value anywhere still holds an unexpanded `$(…)` build setting.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <path/to/App.app> <source Info.plist>" >&2
  exit 2
fi

APP="$1"
SOURCE_PLIST="$2"
BUILT_PLIST="${APP}/Info.plist"
if [[ ! -f "${BUILT_PLIST}" ]]; then
  # A Mac bundle keeps it under Contents/.
  BUILT_PLIST="${APP}/Contents/Info.plist"
fi
if [[ ! -f "${BUILT_PLIST}" ]]; then
  echo "error: no Info.plist in ${APP}" >&2
  exit 1
fi

failures=0
fail() {
  echo "error: $*" >&2
  failures=$((failures + 1))
}

for key in GOOGLE_CLIENT_ID GOOGLE_API_KEY GOOGLE_PROJECT_NUMBER GOOGLE_PROJECT_ID GOOGLE_REDIRECT_URI; do
  if ! value="$(plutil -extract "${key}" raw -o - "${BUILT_PLIST}" 2>/dev/null)"; then
    fail "${key} is missing from ${BUILT_PLIST}"
  elif [[ -z "${value}" ]]; then
    fail "${key} is empty in ${BUILT_PLIST}"
  elif [[ "${value}" == *'$'* ]]; then
    fail "${key} is not resolved in ${BUILT_PLIST}: ${value}"
  fi
done

if plutil -extract BGTaskSchedulerPermittedIdentifiers json -o - "${SOURCE_PLIST}" >/dev/null 2>&1; then
  expected="$(plutil -extract BGTaskSchedulerPermittedIdentifiers json -o - "${SOURCE_PLIST}")"
  if ! actual="$(plutil -extract BGTaskSchedulerPermittedIdentifiers json -o - "${BUILT_PLIST}" 2>/dev/null)"; then
    fail "BGTaskSchedulerPermittedIdentifiers is missing from ${BUILT_PLIST}"
  elif [[ "${actual}" != "${expected}" ]]; then
    fail "BGTaskSchedulerPermittedIdentifiers differs from ${SOURCE_PLIST}: ${actual}"
  fi
fi

if plutil -convert xml1 -o - "${BUILT_PLIST}" | grep -n '\$(' >&2; then
  fail "unexpanded build settings remain in ${BUILT_PLIST} (lines above)"
fi

if [[ ${failures} -gt 0 ]]; then
  exit 1
fi
echo "Info.plist checks passed: ${BUILT_PLIST}"
