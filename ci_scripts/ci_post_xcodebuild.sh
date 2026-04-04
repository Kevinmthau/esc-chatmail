#!/bin/zsh
set -euo pipefail

if [[ ! -d "${CI_APP_STORE_SIGNED_APP_PATH:-}" ]]; then
  exit 0
fi

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
testflight_dir="${repo_root}/TestFlight"

mkdir -p "${testflight_dir}"
git log -1 --pretty=format:"%s" >! "${testflight_dir}/WhatToTest.en-US.txt"
