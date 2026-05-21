#!/bin/zsh
set -euo pipefail

if [[ ! -d "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]]; then
  exit 0
fi

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
testflight_dir="${repo_root}/TestFlight"
what_to_test_file="${testflight_dir}/WhatToTest.en-US.txt"
max_what_to_test_length=4000
git_repo=(git -C "${repo_root}")
commit="${CI_COMMIT:-HEAD}"

if ! "${git_repo[@]}" rev-parse --verify "${commit}^{commit}" >/dev/null 2>&1; then
  commit="HEAD"
fi

function add_unique_area() {
  local area="$1"
  local existing_area

  for existing_area in "${changed_areas[@]}"; do
    if [[ "${existing_area}" == "${area}" ]]; then
      return
    fi
  done

  changed_areas+=("${area}")
}

function area_for_path() {
  local file_path="$1"

  case "${file_path}" in
    esc-chatmail/Services/Security/*|esc-chatmail/Services/AuthSession.swift|esc-chatmail/Views/Main/SignInView.swift)
      print -r -- "Sign-in and session handling"
      ;;
    esc-chatmail/Views/Chat/*|esc-chatmail/ViewModels/ChatViewModel.swift|esc-chatmail/Services/Chat/*)
      print -r -- "Chat"
      ;;
    esc-chatmail/Views/Compose/*|esc-chatmail/ViewModels/ComposeViewModel.swift|esc-chatmail/Services/Compose/*|esc-chatmail/Services/Send/*|esc-chatmail/Services/GmailSendService*)
      print -r -- "Compose and sending"
      ;;
    esc-chatmail/Views/Main/*|esc-chatmail/ViewModels/ConversationListViewModel.swift|esc-chatmail/Services/ConversationList/*)
      print -r -- "Inbox and conversation list"
      ;;
    esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift|esc-chatmail/Views/Components/EmailContent/HTMLFullWebView.swift|esc-chatmail/Views/Chat/HTMLMessageView.swift|esc-chatmail/Services/HTML*|esc-chatmail/Services/HTMLSanitization/*)
      print -r -- "HTML email rendering"
      ;;
    esc-chatmail/Views/Components/EmailContent/*|esc-chatmail/Views/Components/EmailPreview/*|esc-chatmail/Services/Preview/*)
      print -r -- "Email previews"
      ;;
    esc-chatmail/Services/Sync/*|esc-chatmail/Services/API/GmailAPIClient+History.swift|esc-chatmail/Services/API/GmailAPIClient+Messages.swift)
      print -r -- "Mail sync"
      ;;
    esc-chatmail/Services/CoreData/*|esc-chatmail/Models/CoreData/*)
      print -r -- "Local database"
      ;;
    esc-chatmailTests/*)
      print -r -- "Tests"
      ;;
    ci_scripts/*|Scripts/*|XCODE_CLOUD_SETUP.md)
      print -r -- "Build and release automation"
      ;;
    esc-chatmail/Resources/*|esc-chatmail/Configuration/*|esc-chatmail.xcodeproj/*)
      print -r -- "App configuration"
      ;;
    *)
      print -r -- "App behavior touched by this build"
      ;;
  esac
}

function test_prompt_for_area() {
  local area="$1"

  case "${area}" in
    "Chat")
      print -r -- "Open a conversation, send or receive messages, and verify scrolling stays stable."
      ;;
    "Compose and sending")
      print -r -- "Compose, reply, forward, and confirm sent messages appear correctly."
      ;;
    "Inbox and conversation list")
      print -r -- "Refresh the inbox, open conversations, and verify unread and preview state."
      ;;
    "Email previews")
      print -r -- "Open HTML-rich messages in chat previews and confirm cards render cleanly."
      ;;
    "HTML email rendering")
      print -r -- "Open full HTML messages and verify the original email still renders faithfully."
      ;;
    "Mail sync")
      print -r -- "Launch, refresh mail, and verify updated messages and participants appear correctly."
      ;;
    "Local database")
      print -r -- "Upgrade or relaunch the app and confirm existing conversations still load."
      ;;
    "Sign-in and session handling")
      print -r -- "Sign in, relaunch, and confirm the session is restored."
      ;;
    "Tests")
      print -r -- "Smoke test app launch; this build primarily changes automated test coverage."
      ;;
    "Build and release automation")
      print -r -- "Confirm the TestFlight install flow and generated tester notes look correct."
      ;;
    "App configuration")
      print -r -- "Install the build and verify app launch, signing, and configured services."
      ;;
    *)
      print -r -- "Smoke test the changed flow from this build."
      ;;
  esac
}

function print_changed_areas_section() {
  if [[ "${#changed_areas[@]}" -eq 0 ]]; then
    return
  fi

  print -r -- ""
  print -r -- "Changed Areas"
  for area in "${changed_areas[@]}"; do
    print -r -- "- ${area}"
  done
}

function print_what_to_test_section() {
  print -r -- ""
  print -r -- "What to Test"
  if [[ "${#changed_areas[@]}" -gt 0 ]]; then
    for area in "${changed_areas[@]}"; do
      print -r -- "- $(test_prompt_for_area "${area}")"
    done
  else
    print -r -- "- Install the build and smoke test the changed flow."
  fi
}

function truncated_details() {
  local details="$1"
  local max_length="$2"
  local notice="[Details truncated to fit TestFlight limit.]"
  local details_length

  if [[ "${max_length}" -le 0 ]]; then
    return
  fi

  if [[ "${#details}" -le "${max_length}" ]]; then
    print -rn -- "${details}"
    return
  fi

  details_length="${max_length}"
  if [[ "${max_length}" -gt "$(( ${#notice} + 1 ))" ]]; then
    details_length="$(( max_length - ${#notice} - 1 ))"
    print -rn -- "${details[1,details_length]}"
    print -rn -- $'\n'
    print -rn -- "${notice}"
  else
    print -rn -- "${details[1,details_length]}"
  fi
}

commit_subject="$("${git_repo[@]}" log -1 --pretty=format:"%s" "${commit}")"
commit_body="$("${git_repo[@]}" log -1 --pretty=format:"%b" "${commit}" | sed '/^[[:space:]]*$/d')"
changed_files=()
changed_areas=()
has_app_change=0

while IFS= read -r file_path; do
  [[ -z "${file_path}" ]] && continue
  changed_files+=("${file_path}")
  if [[ "${file_path}" != esc-chatmailTests/* ]]; then
    has_app_change=1
  fi
done < <("${git_repo[@]}" show --first-parent --pretty=format: --name-only --no-renames "${commit}")

for file_path in "${changed_files[@]}"; do
  area="$(area_for_path "${file_path}")"
  if [[ "${area}" == "Tests" && "${has_app_change}" -eq 1 ]]; then
    continue
  fi
  add_unique_area "${area}"
done

mkdir -p "${testflight_dir}"

note_intro="$(
  print -r -- "What Changed"
  print -r -- "- ${commit_subject}"
)"
note_suffix="$(
  print_changed_areas_section
  print_what_to_test_section
)"
details_section=""

if [[ -n "${commit_body}" ]]; then
  details_header=$'\n\nDetails\n'
  available_details_length="$(( max_what_to_test_length - ${#note_intro} - ${#note_suffix} - ${#details_header} ))"
  details_text="$(truncated_details "${commit_body}" "${available_details_length}")"
  if [[ -n "${details_text}" ]]; then
    details_section="${details_header}${details_text}"
  fi
fi

note="${note_intro}${details_section}${note_suffix}"
if [[ "${#note}" -gt "${max_what_to_test_length}" ]]; then
  note="${note[1,max_what_to_test_length]}"
fi

print -rn -- "${note}" >! "${what_to_test_file}"
