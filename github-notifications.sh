#!/bin/sh

trap_EXIT() {
  status="$?"

  [ "${status}" -ne 0 ] && printf '%s\n' "Exit Status: ${status}"
}

ensure_utility() {
  command -v "${1}" >/dev/null || {
    printf 'ERROR: %s is not available and is required.\n' "${1}"
    exit 1
  }
}

validate_checks() {
  # Expects a JSON response from the check-runs GitHub API endpoint as stdin.
  # .check_runs.[] | ( .status == "completed" and .conclusion == "success" ): Returns true for each check that has completed successfully.
  # [ ] | all                                                               : Returns true if all checks have completed successfully, or there are no checks at all.
  jq -e '[ .check_runs.[] | ( .status == "completed" and .conclusion == "success" ) ] | all' >/dev/null
}

main() {
  set -euf

  # Ensure required environment variables have been set.
  : "${GH_TOKEN:?"<-- this required environment variable is not set."}"

  # trap will catch all EXIT signals from here forward.
  trap trap_EXIT EXIT

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

  # Get pull request URLs for all relevant notifications.
  curl "$@" "https://api.github.com/notifications" | jq -r '.[] | select( .subject.type == "PullRequest" ) | .subject.url' |
    while IFS= read -r pull_request_url; do
      # Get the branch name (.head.ref) for Dependabot pull requests that bump GitHub Actions dependencies.
      curl "$@" "${pull_request_url}" | jq -r 'select( .head.ref | contains("dependabot/github_actions") ) | .head.ref' |
        while IFS= read -r branch_name; do
          # Verify status checks have run against the latest commit to the branch.
          check_runs_url="${pull_request_url%/pulls/*}/commits/${branch_name}/check-runs"
          if curl "$@" "${check_runs_url}" | validate_checks; then
            # Merge a pull request if all checks are valid.
            curl "$@" --method PUT "${pull_request_url}/merge" -f 'merge_method=squash'
          fi
        done
    done
}

main "$@"
