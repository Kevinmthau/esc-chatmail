#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
script_under_test="${script_dir}/ci_post_xcodebuild.sh"
test_roots=()

function cleanup() {
  local test_root

  for test_root in "${test_roots[@]}"; do
    rm -rf "${test_root}"
  done
}

trap cleanup EXIT

function make_test_repo() {
  local test_root

  test_root="$(mktemp -d /private/tmp/esc-chatmail-ci-test.XXXXXX)"
  test_roots+=("${test_root}")

  mkdir -p "${test_root}/ci_scripts" "${test_root}/signed"
  cp "${script_under_test}" "${test_root}/ci_scripts/ci_post_xcodebuild.sh"
  git -C "${test_root}" init -q
  git -C "${test_root}" config user.name "Codex Test"
  git -C "${test_root}" config user.email "codex@example.com"
  git -C "${test_root}" add ci_scripts/ci_post_xcodebuild.sh
  git -C "${test_root}" commit -q -m "Initial script"

  print -r -- "${test_root}"
}

function commit_file() {
  local test_root="$1"
  local file_path="$2"
  local subject="$3"
  local body="${4:-}"

  mkdir -p "${test_root}/${file_path:h}"
  print -r -- "${subject}" >! "${test_root}/${file_path}"
  git -C "${test_root}" add "${file_path}"

  if [[ -n "${body}" ]]; then
    git -C "${test_root}" commit -q -m "${subject}" -m "${body}"
  else
    git -C "${test_root}" commit -q -m "${subject}"
  fi
}

function generated_note() {
  local test_root="$1"

  CI_APP_STORE_SIGNED_APP_PATH="${test_root}/signed" "${test_root}/ci_scripts/ci_post_xcodebuild.sh"
  < "${test_root}/TestFlight/WhatToTest.en-US.txt"
}

function assert_contains() {
  local value="$1"
  local expected="$2"

  if [[ "${value}" != *"${expected}"* ]]; then
    print -u2 -r -- "Expected output to contain: ${expected}"
    exit 1
  fi
}

function assert_not_contains() {
  local value="$1"
  local unexpected="$2"

  if [[ "${value}" == *"${unexpected}"* ]]; then
    print -u2 -r -- "Expected output not to contain: ${unexpected}"
    exit 1
  fi
}

function assert_length_at_most() {
  local value="$1"
  local max_length="$2"

  if [[ "${#value}" -gt "${max_length}" ]]; then
    print -u2 -r -- "Expected output length <= ${max_length}, got ${#value}"
    exit 1
  fi
}

sign_in_repo="$(make_test_repo)"
commit_file "${sign_in_repo}" "esc-chatmail/Views/Main/SignInView.swift" "Update sign-in screen"
sign_in_note="$(generated_note "${sign_in_repo}")"
assert_contains "${sign_in_note}" "- Sign-in and session handling"
assert_contains "${sign_in_note}" "Sign in, relaunch, and confirm the session is restored."
assert_not_contains "${sign_in_note}" "- Inbox and conversation list"

full_email_repo="$(make_test_repo)"
commit_file "${full_email_repo}" "esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift" "Tune full email rendering"
full_email_note="$(generated_note "${full_email_repo}")"
assert_contains "${full_email_note}" "- HTML email rendering"
assert_contains "${full_email_note}" "Open full HTML messages and verify the original email still renders faithfully."
assert_not_contains "${full_email_note}" "- Email previews"

long_body=""
for _ in {1..300}; do
  long_body+="Long release detail that should not hide tester instructions."$'\n'
done

length_repo="$(make_test_repo)"
commit_file "${length_repo}" "esc-chatmail/Services/Sync/AliasManager.swift" "Refresh aliases" "${long_body}"
length_note="$(generated_note "${length_repo}")"
assert_length_at_most "${length_note}" 4000
assert_contains "${length_note}" "[Details truncated to fit TestFlight limit.]"
assert_contains "${length_note}" "What to Test"
assert_contains "${length_note}" "Launch, refresh mail, and verify updated messages and participants appear correctly."

print -r -- "ci_post_xcodebuild_tests passed"
