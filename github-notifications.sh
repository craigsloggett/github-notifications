#!/bin/sh

trap_EXIT() {
  status="$?"

  [ "${status}" -ne 0 ] && printf '%s\n' "Exit Status: ${status}"
}

ensure_utility() {
  # Expects a utility as the first positional parameter and checks if it is available to run.
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

  # GitHub API Endpoints
  notifications_endpoint="https://api.github.com/notifications"

  printf '%s\n' "Looking for pull request notifications..."

  # Iterate over all pull request notification threads in the authenticated user's inbox.
  curl "$@" "${notifications_endpoint}" | jq -r '.[] | select( .subject.type == "PullRequest" ) | .id' |
    while IFS= read -r thread_id; do
      # Grab a bunch of details from the notification with jq and parameter expansion magic.
      notification_thread_url="${notifications_endpoint}/threads/${thread_id}"
      pull_request_url="$(curl "$@" "${notification_thread_url}" | jq -r '.subject.url')"
      branch_name="$(curl "$@" "${pull_request_url}" | jq -r '.head.ref')"
      git_ref_url="${pull_request_url%/pulls/*}/git/refs/heads/${branch_name}"
      check_runs_url="${pull_request_url%/pulls/*}/commits/${branch_name}/check-runs"

      printf '%s\n' "Processing notification for: ${pull_request_url}"

      # If the pull request is already closed (merged or otherwise), clear the notification and move on to the next one.
      if curl "$@" "${pull_request_url}" | jq -e '( .state == "closed" )' >/dev/null; then
        printf '%s\n' "--> Pull request is already closed, marking the notification as done."

        curl --request PATCH "$@" "${notification_thread_url}"
        curl --request DELETE "$@" "${notification_thread_url}"
        continue
      fi

      # Validate the pull request checks have completed successfully.
      # (returns true if there are no checks configured)
      if curl "$@" "${check_runs_url}" | validate_checks; then
        printf '%s\n' "--> Status checks have passed, considering the Pull Request type."
      else
        printf '%s\n' "--> Status checks have not passed, this pull request requires manual intervention."
        continue
      fi

      # At this point, assume the pull request is open and the ref branch exists, and the status checks have passed.
      case "${branch_name}" in
        *dependabot/github_actions*)
          printf '%s\n' "--> Dependabot is updating a GitHub Actions dependency, merging the pull request."

          # Merge the pull request.
          curl --request PUT "$@" "${pull_request_url}/merge" -d '{ "merge_method": "squash" }'

          # Wait for Dependabot to automatically delete the pull request branch.
          sleep 3

          # Verify the pull request has been closed and merged.
          if curl "$@" "${pull_request_url}" | jq -e '( .state == "closed" and .merged == true )' >/dev/null; then
            # Delete the branch if it still exists.
            if [ "$(curl --write-out '%{http_code}' --output /dev/null "$@" "${git_ref_url}")" -eq 200 ]; then
              curl --request DELETE "$@" "${git_ref_url}"
            fi
          else
            printf '%s\n' "--> The pull request was not merged and closed, this requires manual intervention."
            continue
          fi

          printf '%s\n' "--> Pull request has been merged, marking the notification as done."

          # Mark the notification as read, then done.
          curl --request PATCH "$@" "${notification_thread_url}"
          curl --request DELETE "$@" "${notification_thread_url}"
          ;;
        *dependabot/go_modules*)
          printf '%s\n' "--> Dependabot is updating a Go module dependency, merging the pull request."

          # Merge the pull request.
          curl --request PUT "$@" "${pull_request_url}/merge" -d '{ "merge_method": "squash" }'

          # Wait for Dependabot to automatically delete the pull request branch.
          sleep 3

          # Verify the pull request has been closed and merged.
          if curl "$@" "${pull_request_url}" | jq -e '( .state == "closed" and .merged == true )' >/dev/null; then
            # Delete the branch if it still exists.
            if [ "$(curl --write-out '%{http_code}' --output /dev/null "$@" "${git_ref_url}")" -eq 200 ]; then
              curl --request DELETE "$@" "${git_ref_url}"
            fi
          else
            printf '%s\n' "--> The pull request was not merged and closed, this requires manual intervention."
            continue
          fi

          printf '%s\n' "--> Pull request has been merged, marking the notification as done."

          # Mark the notification as read, then done.
          curl --request PATCH "$@" "${notification_thread_url}"
          curl --request DELETE "$@" "${notification_thread_url}"
          ;;
        *)
          printf '%s\n' "--> This pull request requires manual intervention."
          ;;
      esac
    done
}

main "$@"
