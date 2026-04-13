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

ARGS=()
RUN_PERFORMANCE_TESTS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --performance)
      RUN_PERFORMANCE_TESTS=true
      shift
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "${RUN_PERFORMANCE_TESTS}" == "true" ]]; then
  ARGS+=("-only-testing:esc-chatmailTests/PerformanceRegressionTests")
else
  ARGS+=("-skip-testing:esc-chatmailTests/PerformanceRegressionTests")
fi

xcodebuild test \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  "${ARGS[@]}"
