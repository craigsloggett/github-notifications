#!/bin/sh

trap_EXIT() {
  status="$?"

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

validate_checks() {
  # Expects a JSON response from the check-runs GitHub API endpoint as stdin.
  # Returns false if the response does not contain check runs (e.g. insufficient token permissions).
  # .check_runs // [] | .[]                                                 : Iterate over check runs, defaulting to an empty array if null.
  # ( .status == "completed" and .conclusion == "success" )                 : Returns true for each check that has completed successfully.
  # [ ] | all                                                               : Returns true if all checks have completed successfully, or there are no checks at all.
  jq -e '
    if .check_runs == null then false
    else [ .check_runs[] | ( .status == "completed" and .conclusion == "success" ) ] | all
    end
  ' >/dev/null
}

merge_pull_request() {
  # Expects a pull request endpoint as the first positional parameter and
  # the corresponding git reference (branch) endpoint for the branch that
  # is being merged as the second.
  pull_request_endpoint="${1}"
  head_branch_git_reference_endpoint="${2}"

  # Set the default curl options for all GitHub REST API calls.
  set -- --silent --location
  # Set valid header values for GitHub REST API requests.
  set -- "${@}" -H "${accept_header}" -H "${authorization_header}" -H "${api_version_header}"

  # Merge the pull request.
  curl --request PUT "$@" "${pull_request_endpoint}/merge" -d '{ "merge_method": "squash" }' >/dev/null

  # Wait for GitHub to automatically delete the branch being merged if that is
  # configured.
  sleep 3

  # Verify the pull request has been closed and merged.
  if curl "$@" "${pull_request_endpoint}" | jq -e '( .state == "closed" and .merged == true )' >/dev/null; then
    log "The pull request has been closed and merged, confirming the reference branch has been deleted ..."
    # Delete the branch if it still exists.
    if [ "$(curl --write-out '%{http_code}' --output /dev/null "$@" "${head_branch_git_reference_endpoint}")" -eq 200 ]; then
      curl --request DELETE "$@" "${head_branch_git_reference_endpoint}" >/dev/null
      log "The pull request reference branch has been successfully deleted."
    fi
  else
    warn "The pull request was not merged, this requires manual intervention."
    return 1
  fi
}

main() {
  set -euf

  # Ensure required environment variables have been set.
  : "${GH_TOKEN:?"<-- this required environment variable is not set."}"

  # Validate the owner argument.
  owner="${1:?"Usage: merge-dependabot.sh <owner>"}"

  # trap will catch all EXIT signals from here forward.
  trap trap_EXIT EXIT

  # ANSI escape sequences used for text output.
  bold_yellow='\033[1;33m'
  bold_red='\033[1;31m'
  bold='\033[1m'
  reset='\033[m'

  # Ensure required utilities are available.
  for utility in curl jq; do
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
  # GitHub Search API paginates at 30 results by default, request up to 100.
  search_query="is:pr+is:open+author:app/dependabot+user:${owner}"
  search_results_json="$(curl "$@" "${search_endpoint}?q=${search_query}&per_page=100")"

  total_count="$(printf '%s' "${search_results_json}" | jq -r '.total_count')"
  log "Found ${total_count} open dependabot pull request(s)."

  # Exit early if there are no results.
  [ "${total_count}" -eq 0 ] && return 0

  # Iterate over each pull request, sorted by oldest first to handle dependency chains.
  printf '%s' "${search_results_json}" | jq -r '.items | sort_by(.created_at) | .[].pull_request.url' |
    while read -r pull_request_endpoint; do
      # Isolate details of the pull request being processed.
      pull_request_json="$(curl "$@" "${pull_request_endpoint}")"
      repository_endpoint="$(printf '%s' "${pull_request_json}" | jq -r '.base.repo.url')"
      repository_full_name="$(printf '%s' "${pull_request_json}" | jq -r '.base.repo.full_name')"
      pull_request_number="$(printf '%s' "${pull_request_json}" | jq -r '.number')"
      # The branch whose changes are combined into the base branch when you
      # merge a pull request. Also known as the "compare branch."
      head_branch_name="$(printf '%s' "${pull_request_json}" | jq -r '.head.ref')"
      # The REF in the URL must be formatted as heads/<branch name> for
      # branches and tags/<tag name> for tags.
      head_branch_git_reference_endpoint="${repository_endpoint}/git/ref/heads/${head_branch_name}"
      # The REF can be a SHA, branch name, or a tag name.
      check_runs_endpoint="${repository_endpoint}/commits/${head_branch_name}/check-runs"
      # Check if the pull request is mergeable.
      mergeable="$(printf '%s' "${pull_request_json}" | jq -r '.mergeable')"

      log "" # Create a visual break for new pull requests.
      log "Processing: ${repository_full_name}#${pull_request_number} (${head_branch_name})"

      # Skip pull requests that have merge conflicts.
      if [ "${mergeable}" != "true" ]; then
        warn "Pull request has merge conflicts, skipping."
        continue
      fi

      # Validate the pull request checks have completed successfully.
      # (returns true if there are no checks configured)
      if curl "$@" "${check_runs_endpoint}" | validate_checks; then
        log "Status checks have passed, merging the pull request ..."
      else
        warn "Status checks have not passed, this pull request requires manual intervention."
        continue
      fi

      # Merge the pull request.
      merge_pull_request "${pull_request_endpoint}" "${head_branch_git_reference_endpoint}" || continue

      log "Pull request has been merged."
    done
}

main "$@"
