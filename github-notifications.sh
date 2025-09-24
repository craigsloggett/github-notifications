#!/bin/sh

trap_EXIT() {
  status="$?"

  [ "${status}" -ne 0 ] && printf '%s\n' "Exit Status: ${status}"
}

ensure_utility() {
  # Expects a utility as the first positional parameter and checks if it is available to run.
  utility="${1}"

  command -v "${utility}" >/dev/null || {
    printf 'ERROR: %s is not available and is required.\n' "${utility}"
    exit 1
  }
}

validate_checks() {
  # Expects a JSON response from the check-runs GitHub API endpoint as stdin.
  # .check_runs.[] | ( .status == "completed" and .conclusion == "success" ): Returns true for each check that has completed successfully.
  # [ ] | all                                                               : Returns true if all checks have completed successfully, or there are no checks at all.
  jq -e '[ .check_runs.[] | ( .status == "completed" and .conclusion == "success" ) ] | all' >/dev/null
}

merge_pull_request() {
  # Expects a pull request URL as the first positional parameter and a URL to
  # the reference branch that is being merged as the second.
  pull_request_url="${1}"
  git_ref_url="${2}"

  # Merge the pull request.
  curl --request PUT "$@" "${pull_request_url}/merge" -d '{ "merge_method": "squash" }'

  # Wait for GitHub to automatically delete the branch being merged if that is
  # configured.
  sleep 3

  # Verify the pull request has been closed and merged.
  if curl "$@" "${pull_request_url}" | jq -e '( .state == "closed" and .merged == true )' >/dev/null; then
    # Delete the branch if it still exists.
    if [ "$(curl --write-out '%{http_code}' --output /dev/null "$@" "${git_ref_url}")" -eq 200 ]; then
      curl --request DELETE "$@" "${git_ref_url}"
    fi
  else
    printf 'WARN: The pull request was not merged, this requires manual intervention.\n'
    return 1
  fi
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

  # GitHub API Endpoints
  notifications_endpoint="https://api.github.com/notifications"

  printf 'INFO: Listing notifications for the authenticated user ...\n'

  # Filter on subject type to grab pull request notifications.
  response="$(curl "$@" "${notifications_endpoint}" | jq -r '.[] | select( .subject.type == "PullRequest" )')"

  printf '%s' "${response}" | jq -r '.id' |
    while read -r thread_id; do
      thread_json="$(printf '%s' "${response}" | jq -r "select( .id == \"${thread_id}\" )")"
      # Grab a bunch of details from the notification with jq and parameter expansion magic.
      notification_thread_url="$(printf '%s' "${thread_json}" | jq -r '.url')"
      pull_request_url="$(printf '%s' "${thread_json}" | jq -r '.subject.url')"
      branch_name="$(curl "$@" "${pull_request_url}" | jq -r '.head.ref')"
      git_ref_url="${pull_request_url%/pulls/*}/git/refs/heads/${branch_name}"
      check_runs_url="${pull_request_url%/pulls/*}/commits/${branch_name}/check-runs"

      printf 'INFO: Processing notification for: %s\n' "${pull_request_url}"

      # If the pull request is already closed (merged or otherwise), clear the notification and move on to the next one.
      if curl "$@" "${pull_request_url}" | jq -e '( .state == "closed" )' >/dev/null; then
        printf 'INFO: Pull request is closed, marking the notification as done.\n'

        curl --request PATCH "$@" "${notification_thread_url}"
        curl --request DELETE "$@" "${notification_thread_url}"
        continue
      fi

      # Validate the pull request checks have completed successfully.
      # (returns true if there are no checks configured)
      if curl "$@" "${check_runs_url}" | validate_checks; then
        printf 'INFO: Status checks have passed, considering the Pull Request type.\n'
      else
        printf 'WARN: Status checks have not passed, this pull request requires manual intervention.\n'
        continue
      fi

      # At this point, assume the pull request is open and the ref branch exists, and the status checks have passed.
      case "${branch_name}" in
        *dependabot/github_actions*)
          printf 'INFO: Dependabot is updating a GitHub Actions dependency, merging the pull request.\n'

          # Merge the pull request.
          merge_pull_request "${pull_request_url}" "${git_ref_url}" || continue

          printf 'INFO: Pull request has been merged, marking the notification as done.\n'

          # Mark the notification as read, then done.
          curl --request PATCH "$@" "${notification_thread_url}"
          curl --request DELETE "$@" "${notification_thread_url}"
          ;;
        *dependabot/go_modules*)
          printf 'INFO: Dependabot is updating a Go module dependency, merging the pull request.\n'

          # Merge the pull request.
          merge_pull_request "${pull_request_url}" "${git_ref_url}" || continue

          printf 'INFO: Pull request has been merged, marking the notification as done.\n'

          # Mark the notification as read, then done.
          curl --request PATCH "$@" "${notification_thread_url}"
          curl --request DELETE "$@" "${notification_thread_url}"
          ;;
        *)
          printf 'WARN: This pull request requires manual intervention.\n'
          ;;
      esac
    done
}

main "$@"
