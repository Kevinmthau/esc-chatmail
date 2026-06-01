#!/usr/bin/env bash
set -euo pipefail

API_BASE="${ASC_API_BASE:-https://api.appstoreconnect.apple.com}"
PROJECT_PATH="${ASC_CONTAINER_FILE_PATH:-esc-chatmail.xcodeproj}"
SCHEME="${ASC_SCHEME:-esc-chatmail}"
BRANCH="${ASC_BRANCH:-main}"

usage() {
  cat <<'USAGE'
Usage:
  Scripts/xcode-cloud-api.sh describe-local-product
  Scripts/xcode-cloud-api.sh list-products
  Scripts/xcode-cloud-api.sh list-versions
  Scripts/xcode-cloud-api.sh list-git-references <repository-id>
  Scripts/xcode-cloud-api.sh list-workflows <product-id>
  Scripts/xcode-cloud-api.sh print-pr-test-workflow-payload
  Scripts/xcode-cloud-api.sh print-testflight-workflow-payload
  Scripts/xcode-cloud-api.sh create-pr-test-workflow
  Scripts/xcode-cloud-api.sh create-testflight-workflow
  Scripts/xcode-cloud-api.sh create-default-workflows
  Scripts/xcode-cloud-api.sh start-build <workflow-id> [git-reference-id]

Authentication environment:
  ASC_KEY_ID              App Store Connect API key ID
  ASC_ISSUER_ID           App Store Connect issuer ID
  ASC_PRIVATE_KEY_PATH    Path to the AuthKey_<key-id>.p8 private key

Workflow creation environment:
  ASC_CI_PRODUCT_ID       Xcode Cloud ciProducts ID
  ASC_CI_REPOSITORY_ID    Primary scmRepositories ID for the product
  ASC_CI_XCODE_VERSION_ID ciXcodeVersions ID
  ASC_CI_MACOS_VERSION_ID ciMacOsVersions ID

Optional environment:
  ASC_BRANCH              Branch for default triggers; defaults to main
  ASC_CONTAINER_FILE_PATH Project/workspace path; defaults to esc-chatmail.xcodeproj
  ASC_SCHEME              Xcode scheme; defaults to esc-chatmail
  ASC_TEST_DEVICE_NAME    Test simulator name; defaults to iPhone 17 Pro
  ASC_TEST_DEVICE_ID      Test simulator device type ID
  ASC_TEST_RUNTIME_NAME   Test runtime name; defaults to iOS 26.5
  ASC_TEST_RUNTIME_ID     Test runtime identifier
  ASC_API_BASE            API base URL; defaults to https://api.appstoreconnect.apple.com

Notes:
  The App Store Connect API can create workflows only after Xcode Cloud has a product
  and repository relationship for this app. If list-products returns no esc-chatmail
  product, finish the first Xcode Cloud setup/grant in Xcode or App Store Connect,
  then rerun the CLI commands here.
USAGE
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_auth() {
  require_command curl
  require_command ruby

  local missing=()
  for var_name in ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_PATH; do
    if [[ -z "${!var_name:-}" ]]; then
      missing+=("$var_name")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "Missing App Store Connect API environment: ${missing[*]}" >&2
    exit 1
  fi

  if [[ ! -f "${ASC_PRIVATE_KEY_PATH}" ]]; then
    echo "ASC_PRIVATE_KEY_PATH does not exist: ${ASC_PRIVATE_KEY_PATH}" >&2
    exit 1
  fi
}

require_workflow_ids() {
  local missing=()
  for var_name in ASC_CI_PRODUCT_ID ASC_CI_REPOSITORY_ID ASC_CI_XCODE_VERSION_ID ASC_CI_MACOS_VERSION_ID; do
    if [[ -z "${!var_name:-}" ]]; then
      missing+=("$var_name")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "Missing workflow creation environment: ${missing[*]}" >&2
    exit 1
  fi
}

jwt() {
  ruby <<'RUBY'
require "base64"
require "json"
require "openssl"

def base64url(value)
  Base64.urlsafe_encode64(value).delete("=")
end

def fixed_width_int(integer, byte_count)
  hex = integer.to_i.to_s(16)
  hex = "0#{hex}" if hex.length.odd?
  bytes = [hex].pack("H*")
  raise "ECDSA integer is wider than #{byte_count} bytes" if bytes.bytesize > byte_count
  ("\x00" * (byte_count - bytes.bytesize)) + bytes
end

header = {
  alg: "ES256",
  kid: ENV.fetch("ASC_KEY_ID"),
  typ: "JWT"
}
payload = {
  iss: ENV.fetch("ASC_ISSUER_ID"),
  exp: Time.now.to_i + 20 * 60,
  aud: "appstoreconnect-v1"
}

signing_input = [
  base64url(JSON.generate(header)),
  base64url(JSON.generate(payload))
].join(".")

key = OpenSSL::PKey.read(File.read(ENV.fetch("ASC_PRIVATE_KEY_PATH")))
signature_der = key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
signature_sequence = OpenSSL::ASN1.decode(signature_der)
r = fixed_width_int(signature_sequence.value[0].value, 32)
s = fixed_width_int(signature_sequence.value[1].value, 32)

puts "#{signing_input}.#{base64url(r + s)}"
RUBY
}

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local token

  require_auth
  token="$(jwt)"

  if [[ -n "${body}" ]]; then
    curl -fsS \
      -X "${method}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --data-binary "${body}" \
      "${API_BASE}${path}"
  else
    curl -fsS \
      -X "${method}" \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/json" \
      "${API_BASE}${path}"
  fi
}

workflow_payload() {
  local workflow_kind="$1"

  require_workflow_ids

  WORKFLOW_KIND="${workflow_kind}" \
  PROJECT_PATH="${PROJECT_PATH}" \
  SCHEME="${SCHEME}" \
  BRANCH="${BRANCH}" \
  TEST_DEVICE_NAME="${ASC_TEST_DEVICE_NAME:-iPhone 17 Pro}" \
  TEST_DEVICE_ID="${ASC_TEST_DEVICE_ID:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}" \
  TEST_RUNTIME_NAME="${ASC_TEST_RUNTIME_NAME:-iOS 26.5}" \
  TEST_RUNTIME_ID="${ASC_TEST_RUNTIME_ID:-com.apple.CoreSimulator.SimRuntime.iOS-26-5}" \
  ruby <<'RUBY'
require "json"

def branch_patterns(branch)
  {
    isAllMatch: false,
    patterns: [
      {
        pattern: branch,
        isPrefix: false
      }
    ]
  }
end

def all_branches
  {
    isAllMatch: true,
    patterns: []
  }
end

kind = ENV.fetch("WORKFLOW_KIND")
branch = ENV.fetch("BRANCH")
scheme = ENV.fetch("SCHEME")
project_path = ENV.fetch("PROJECT_PATH")
test_destination = {
  deviceTypeName: ENV.fetch("TEST_DEVICE_NAME"),
  deviceTypeIdentifier: ENV.fetch("TEST_DEVICE_ID"),
  runtimeName: ENV.fetch("TEST_RUNTIME_NAME"),
  runtimeIdentifier: ENV.fetch("TEST_RUNTIME_ID"),
  kind: "SIMULATOR"
}

case kind
when "pr-test"
  name = "PR Tests"
  description = "Runs the esc-chatmail test plan for pull requests targeting #{branch}."
  action = {
    name: "Test",
    actionType: "TEST",
    destination: "ANY_IOS_SIMULATOR",
    testConfiguration: {
      kind: "USE_SCHEME_SETTINGS",
      testDestinations: [test_destination]
    },
    scheme: scheme,
    platform: "IOS",
    isRequiredToPass: true
  }
  start_conditions = {
    pullRequestStartCondition: {
      source: all_branches,
      destination: branch_patterns(branch),
      autoCancel: true
    },
    manualPullRequestStartCondition: {
      source: all_branches,
      destination: branch_patterns(branch)
    }
  }
when "testflight"
  name = "#{branch} TestFlight"
  description = "Archives #{branch} for TestFlight and App Store-eligible distribution."
  action = {
    name: "Archive",
    actionType: "ARCHIVE",
    destination: "ANY_IOS_DEVICE",
    buildDistributionAudience: "APP_STORE_ELIGIBLE",
    scheme: scheme,
    platform: "IOS",
    isRequiredToPass: true
  }
  start_conditions = {
    branchStartCondition: {
      source: branch_patterns(branch),
      autoCancel: true
    },
    manualBranchStartCondition: {
      source: branch_patterns(branch)
    }
  }
else
  raise "Unknown workflow kind: #{kind}"
end

payload = {
  data: {
    type: "ciWorkflows",
    attributes: {
      name: name,
      description: description,
      actions: [action],
      isEnabled: true,
      clean: true,
      containerFilePath: project_path
    }.merge(start_conditions),
    relationships: {
      product: {
        data: {
          type: "ciProducts",
          id: ENV.fetch("ASC_CI_PRODUCT_ID")
        }
      },
      repository: {
        data: {
          type: "scmRepositories",
          id: ENV.fetch("ASC_CI_REPOSITORY_ID")
        }
      },
      xcodeVersion: {
        data: {
          type: "ciXcodeVersions",
          id: ENV.fetch("ASC_CI_XCODE_VERSION_ID")
        }
      },
      macOsVersion: {
        data: {
          type: "ciMacOsVersions",
          id: ENV.fetch("ASC_CI_MACOS_VERSION_ID")
        }
      }
    }
  }
}

puts JSON.pretty_generate(payload)
RUBY
}

build_run_payload() {
  local workflow_id="$1"
  local git_reference_id="${2:-}"

  WORKFLOW_ID="${workflow_id}" \
  GIT_REFERENCE_ID="${git_reference_id}" \
  ruby <<'RUBY'
require "json"

relationships = {
  workflow: {
    data: {
      type: "ciWorkflows",
      id: ENV.fetch("WORKFLOW_ID")
    }
  }
}

unless ENV.fetch("GIT_REFERENCE_ID", "").empty?
  relationships[:sourceBranchOrTag] = {
    data: {
      type: "scmGitReferences",
      id: ENV.fetch("GIT_REFERENCE_ID")
    }
  }
end

puts JSON.generate({
  data: {
    type: "ciBuildRuns",
    attributes: {
      clean: true
    },
    relationships: relationships
  }
})
RUBY
}

describe_local_product() {
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcodebuild -project esc-chatmail.xcodeproj -describeAllArchivableProducts -json
}

list_products() {
  api GET '/v1/ciProducts?filter%5BproductType%5D=APP&include=app,primaryRepositories&fields%5BciProducts%5D=name,createdDate,productType,app,bundleId,workflows,primaryRepositories&fields%5BscmRepositories%5D=ownerName,repositoryName,httpCloneUrl,sshCloneUrl,defaultBranch'
}

list_versions() {
  api GET '/v1/ciXcodeVersions?include=macOsVersions&fields%5BciXcodeVersions%5D=version,name,macOsVersions,testDestinations&fields%5BciMacOsVersions%5D=version,name&limit=200&limit%5BmacOsVersions%5D=50'
}

list_git_references() {
  local repository_id="${1:-}"

  if [[ -z "${repository_id}" ]]; then
    echo "Usage: Scripts/xcode-cloud-api.sh list-git-references <repository-id>" >&2
    exit 1
  fi

  api GET "/v1/scmRepositories/${repository_id}/gitReferences?fields%5BscmGitReferences%5D=name,canonicalName,isDeleted,kind&limit=200"
}

list_workflows() {
  local product_id="${1:-}"

  if [[ -z "${product_id}" ]]; then
    echo "Usage: Scripts/xcode-cloud-api.sh list-workflows <product-id>" >&2
    exit 1
  fi

  api GET "/v1/ciProducts/${product_id}/workflows?fields%5BciWorkflows%5D=name,description,isEnabled,branchStartCondition,pullRequestStartCondition,actions,xcodeVersion,macOsVersion&include=xcodeVersion,macOsVersion&limit=200"
}

create_workflow() {
  local workflow_kind="$1"
  local payload

  payload="$(workflow_payload "${workflow_kind}")"
  api POST '/v1/ciWorkflows' "${payload}"
}

start_build() {
  local workflow_id="${1:-}"
  local git_reference_id="${2:-}"
  local payload

  if [[ -z "${workflow_id}" ]]; then
    echo "Usage: Scripts/xcode-cloud-api.sh start-build <workflow-id> [git-reference-id]" >&2
    exit 1
  fi

  payload="$(build_run_payload "${workflow_id}" "${git_reference_id}")"
  api POST '/v1/ciBuildRuns' "${payload}"
}

command_name="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "${command_name}" in
  describe-local-product)
    describe_local_product "$@"
    ;;
  list-products)
    list_products "$@"
    ;;
  list-versions)
    list_versions "$@"
    ;;
  list-git-references)
    list_git_references "$@"
    ;;
  list-workflows)
    list_workflows "$@"
    ;;
  print-pr-test-workflow-payload)
    workflow_payload pr-test
    ;;
  print-testflight-workflow-payload)
    workflow_payload testflight
    ;;
  create-pr-test-workflow)
    create_workflow pr-test
    ;;
  create-testflight-workflow)
    create_workflow testflight
    ;;
  create-default-workflows)
    create_workflow pr-test
    printf '\n'
    create_workflow testflight
    ;;
  start-build)
    start_build "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
