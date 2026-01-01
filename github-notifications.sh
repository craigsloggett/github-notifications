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
  # .check_runs.[] | ( .status == "completed" and .conclusion == "success" ): Returns true for each check that has completed successfully.
  # [ ] | all                                                               : Returns true if all checks have completed successfully, or there are no checks at all.
  jq -e '[ .check_runs.[] | ( .status == "completed" and .conclusion == "success" ) ] | all' >/dev/null
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
  notifications_endpoint="https://api.github.com/notifications"

  log "Listing notifications for the authenticated user ..."

  # Filter the notifications endpoint response on subject type to grab pull request notifications.
  pull_request_notifications_json="$(curl "$@" "${notifications_endpoint}" | jq -r '.[] | select( .subject.type == "PullRequest" )')"

  # Iterate over each unique pull request notification thread identifier.
  printf '%s' "${pull_request_notifications_json}" | jq -r '.id' |
    while read -r notification_thread_id; do
      # Isolate details of the notification being processed.
      notification_thread_json="$(printf '%s' "${pull_request_notifications_json}" | jq -r "select( .id == \"${notification_thread_id}\" )")"
      notification_thread_endpoint="$(printf '%s' "${notification_thread_json}" | jq -r '.url')"
      repository_endpoint="$(printf '%s' "${notification_thread_json}" | jq -r '.repository.url')"
      pull_request_endpoint="$(printf '%s' "${notification_thread_json}" | jq -r '.subject.url')"

      # Isolate details of the pull request being processed.
      pull_request_json="$(curl "$@" "${pull_request_endpoint}")"
      # The branch whose changes are combined into the base branch when you
      # merge a pull request. Also known as the "compare branch."
      head_branch_name="$(printf '%s' "${pull_request_json}" | jq -r '.head.ref')"
      # The REF in the URL must be formatted as heads/<branch name> for
      # branches and tags/<tag name> for tags.
      head_branch_git_reference_endpoint="${repository_endpoint}/git/ref/heads/${head_branch_name}"
      # The REF can be a SHA, branch name, or a tag name.
      check_runs_endpoint="${repository_endpoint}/commits/${head_branch_name}/check-runs"

      log "" # Create a visual break for new notifications.
      log "Processing notification for: ${pull_request_endpoint}"

      # If the pull request is already closed (merged or otherwise), clear the notification and move on to the next one.
      if printf '%s' "${pull_request_json}" | jq -e '( .state == "closed" )' >/dev/null; then
        log "Pull request is closed, marking the notification as done ..."

        curl --request PATCH "$@" "${notification_thread_endpoint}"
        curl --request DELETE "$@" "${notification_thread_endpoint}"
        continue
      fi

      # Validate the pull request checks have completed successfully.
      # (returns true if there are no checks configured)
      if curl "$@" "${check_runs_endpoint}" | validate_checks; then
        log "Status checks have passed, reviewing the Pull Request type ..."
      else
        warn "Status checks have not passed, this pull request requires manual intervention."
        continue
      fi

      # At this point, assume the pull request is open and the ref branch exists, and the status checks have passed.
      case "${head_branch_name}" in
        *dependabot/github_actions*)
          log "Dependabot is updating a GitHub Actions dependency, merging the pull request ..."

          # Merge the pull request.
          merge_pull_request "${pull_request_endpoint}" "${head_branch_git_reference_endpoint}" || continue

          # Mark the notification as read, then done.
          log "Pull request has been merged, marking the notification as done ..."
          curl --request PATCH "$@" "${notification_thread_endpoint}"
          curl --request DELETE "$@" "${notification_thread_endpoint}"
          ;;
        *dependabot/go_modules*)
          log "Dependabot is updating a Go module dependency, merging the pull request ..."

          # Merge the pull request.
          merge_pull_request "${pull_request_endpoint}" "${head_branch_git_reference_endpoint}" || continue

          log "Pull request has been merged, marking the notification as done ..."

          # Mark the notification as read, then done.
          curl --request PATCH "$@" "${notification_thread_endpoint}"
          curl --request DELETE "$@" "${notification_thread_endpoint}"
          ;;
        *)
          warn "This pull request requires manual intervention."
          ;;
      esac
    done
}

main "$@"
