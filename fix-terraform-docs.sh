#!/bin/sh

trap_EXIT() {
  status="$?"

  # Clean up the temporary directory if it exists.
  if [ -n "${tmpdir:-}" ] && [ -d "${tmpdir}" ]; then
    rm -rf "${tmpdir}"
  fi

  [ "${status}" -ne 0 ] && printf '%s\n' "Exit Status: ${status}"
}

log() {
  message="${1}"

  printf '%b%s%b %s\n' "${bold}" "INFO:" "${reset}" "${message}"
}

warn() {
  message="${1}"

  printf '%b%s%b %s\n' "${bold_yellow}" "WARN:" "${reset}" "${message}"
}

error() {
  message="${1}"

  printf '%b%s%b %s\n' "${bold_red}" "ERROR:" "${reset}" "${message}"
}

ensure_utility() {
  # Expects a utility as the first positional parameter and checks if it is available to run.
  utility="${1}"

  command -v "${utility}" >/dev/null || {
    error "The following utility is not available and is required --> ${utility}"
    exit 1
  }
}

has_terraform_docs_failure() {
  # Expects a JSON response from the check-runs GitHub API endpoint as stdin.
  # Returns true if there is a completed check run with "docs" in the name that has failed.
  jq -e '
    if .check_runs == null then false
    else [ .check_runs[] | select(.name | test("docs"; "i")) | .conclusion == "failure" ] | any
    end
  ' >/dev/null
}

fix_terraform_docs() {
  # Expects the clone URL as the first positional parameter and the branch
  # name as the second.
  clone_url="${1}"
  branch_name="${2}"

  tmpdir="$(mktemp -d)"

  log "Cloning ${branch_name} to temporary directory ..."
  git clone --quiet --depth 1 --branch "${branch_name}" "${clone_url}" "${tmpdir}"

  # Run terraform-docs. Use the repo's config if it exists, otherwise use defaults.
  if [ -f "${tmpdir}/.terraform-docs.yml" ]; then
    terraform-docs "${tmpdir}"
  else
    terraform-docs markdown table --output-file README.md --output-mode inject "${tmpdir}"
  fi

  # Check if terraform-docs produced any changes.
  if git -C "${tmpdir}" diff --quiet; then
    log "No documentation changes needed."
    rm -rf "${tmpdir}"
    tmpdir=""
    return 1
  fi

  log "Documentation updated, committing and pushing ..."
  git -C "${tmpdir}" add README.md
  git -C "${tmpdir}" commit --quiet -m "docs: Regenerate terraform-docs"
  git -C "${tmpdir}" push --quiet

  rm -rf "${tmpdir}"
  tmpdir=""
}

main() {
  set -euf

  # Ensure required environment variables have been set.
  : "${GH_TOKEN:?"<-- this required environment variable is not set."}"

  # Validate the owner argument.
  owner="${1:?"Usage: fix-terraform-docs.sh <owner>"}"

  # Initialize the temporary directory variable for the trap.
  tmpdir=""

  # trap will catch all EXIT signals from here forward.
  trap trap_EXIT EXIT

  # ANSI escape sequences used for text output.
  bold_yellow='\033[1;33m'
  bold_red='\033[1;31m'
  bold='\033[1m'
  reset='\033[m'

  # Ensure required utilities are available.
  for utility in curl jq git terraform-docs; do
    ensure_utility "${utility}"
  done

  # Header values for the GitHub REST API.
  accept_header="Accept: application/vnd.github+json"
  authorization_header="Authorization: Bearer ${GH_TOKEN}"
  api_version_header="X-GitHub-Api-Version: 2022-11-28"

  # Set the default curl options for all GitHub REST API calls.
  set -- --silent --location
  # Set valid header values for GitHub REST API requests.
  set -- "${@}" -H "${accept_header}" -H "${authorization_header}" -H "${api_version_header}"

  # GitHub API Endpoints
  search_endpoint="https://api.github.com/search/issues"

  log "Searching for open dependabot pull requests owned by ${owner} ..."

  # Search for open pull requests authored by dependabot for the given owner.
  search_query="is:pr+is:open+author:app/dependabot+user:${owner}"
  search_results_json="$(curl "$@" "${search_endpoint}?q=${search_query}&per_page=100")"

  total_count="$(printf '%s' "${search_results_json}" | jq -r '.total_count')"
  log "Found ${total_count} open dependabot pull request(s)."

  # Exit early if there are no results.
  [ "${total_count}" -eq 0 ] && return 0

  # Iterate over each pull request, sorted by oldest first.
  printf '%s' "${search_results_json}" | jq -r '.items | sort_by(.created_at) | .[].pull_request.url' |
    while read -r pull_request_endpoint; do
      # Isolate details of the pull request being processed.
      pull_request_json="$(curl "$@" "${pull_request_endpoint}")"
      repository_endpoint="$(printf '%s' "${pull_request_json}" | jq -r '.base.repo.url')"
      repository_full_name="$(printf '%s' "${pull_request_json}" | jq -r '.base.repo.full_name')"
      pull_request_number="$(printf '%s' "${pull_request_json}" | jq -r '.number')"
      clone_url="$(printf '%s' "${pull_request_json}" | jq -r '.head.repo.clone_url')"
      head_branch_name="$(printf '%s' "${pull_request_json}" | jq -r '.head.ref')"
      check_runs_endpoint="${repository_endpoint}/commits/${head_branch_name}/check-runs"
      mergeable="$(printf '%s' "${pull_request_json}" | jq -r '.mergeable')"

      log "" # Create a visual break for new pull requests.
      log "Processing: ${repository_full_name}#${pull_request_number} (${head_branch_name})"

      # Skip pull requests that have merge conflicts.
      if [ "${mergeable}" != "true" ]; then
        warn "Pull request has merge conflicts, skipping."
        continue
      fi

      # Check if there is a terraform-docs failure specifically.
      check_runs_json="$(curl "$@" "${check_runs_endpoint}")"
      if printf '%s' "${check_runs_json}" | has_terraform_docs_failure; then
        log "Detected terraform-docs failure, attempting to fix ..."
        fix_terraform_docs "${clone_url}" "${head_branch_name}" || {
          warn "Could not fix terraform-docs, skipping."
          continue
        }
        log "Fix pushed, CI will re-run."
      else
        log "No terraform-docs failure detected, skipping."
      fi
    done
}

main "$@"
