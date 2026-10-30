#!/bin/sh
#
# Triage GitHub pull request notifications for the authenticated user.

set -euf

# Ensure required utilities are available.
for utility in gh jq; do
  if ! command -v "${utility}" >/dev/null 2>&1; then
    printf '%s\n' "ERROR: The following utility is not available and is required --> ${utility}" >&2
    exit 1
  fi
done

# trap_exit reports a non-zero exit status to stderr when the script ends.
trap_exit() (
  status="$?"

  if [ "${status}" -ne 0 ]; then
    printf '%s\n' "Exit Status: ${status}" >&2
  fi
)

# log prints an informational message to stdout.
log() (
  message="${1:?message is required}"

  printf '%b%s%b %s\n' "${bold}" "INFO:" "${reset}" "${message}"
)

# warn prints a warning message to stdout.
warn() (
  message="${1:?message is required}"

  printf '%b%s%b %s\n' "${bold_yellow}" "WARN:" "${reset}" "${message}"
)

# die prints an error message to stderr and aborts the script.
die() {
  message="${1:?message is required}"

  printf '%b%s%b %s\n' "${bold_red}" "ERROR:" "${reset}" "${message}" >&2
  exit 1
}

# validate_checks reads a check-runs API response from stdin and succeeds when
# every check run has completed successfully, or when there are no check runs.
validate_checks() {
  jq -e '[ .check_runs[] | ( .status == "completed" and .conclusion == "success" ) ] | all' >/dev/null
}

# mark_notification_done marks a notification thread as read, then as done.
mark_notification_done() (
  notification_thread_endpoint="${1:?notification thread endpoint is required}"

  gh api --silent --method PATCH "${notification_thread_endpoint}" &&
    gh api --silent --method DELETE "${notification_thread_endpoint}"
)

# triage_pull_request_notification reports on the pull request behind a
# notification thread, marking the thread as done when the pull request is
# closed, and never changing the pull request itself.
triage_pull_request_notification() (
  notification_thread_json="${1:?notification thread JSON is required}"

  notification_thread_endpoint="$(printf '%s' "${notification_thread_json}" | jq -r '.url')"
  repository_endpoint="$(printf '%s' "${notification_thread_json}" | jq -r '.repository.url')"
  pull_request_endpoint="$(printf '%s' "${notification_thread_json}" | jq -r '.subject.url')"

  printf '\n' # Create a visual break for new notifications.
  log "Processing notification for: ${pull_request_endpoint}"

  if ! pull_request_json="$(gh api "${pull_request_endpoint}")"; then
    warn "Unable to retrieve the pull request, this notification requires manual intervention."
    return
  fi

  # If the pull request is already closed (merged or otherwise), clear the notification and move on to the next one.
  if printf '%s' "${pull_request_json}" | jq -e '( .state == "closed" )' >/dev/null; then
    log "Pull request is closed, marking the notification as done ..."

    mark_notification_done "${notification_thread_endpoint}" ||
      warn "Unable to mark the notification as done, this notification requires manual intervention."
    return
  fi

  # The branch whose changes are combined into the base branch when you
  # merge a pull request. Also known as the "compare branch."
  head_branch_name="$(printf '%s' "${pull_request_json}" | jq -r '.head.ref')"
  # The REF can be a SHA, branch name, or a tag name.
  check_runs_endpoint="${repository_endpoint}/commits/${head_branch_name}/check-runs"

  if ! check_runs_json="$(gh api "${check_runs_endpoint}")"; then
    warn "Unable to retrieve the status checks, this pull request requires manual intervention."
    return
  fi

  # Validate the pull request checks have completed successfully.
  # (returns true if there are no checks configured)
  if ! printf '%s' "${check_runs_json}" | validate_checks; then
    warn "Status checks have not passed, this pull request requires manual intervention."
    return
  fi

  log "Status checks have passed, reviewing the Pull Request type ..."

  # At this point, the pull request is open and the status checks have passed.
  case "${head_branch_name}" in
    *dependabot/github_actions*)
      log "Dependabot is updating a GitHub Actions dependency, this pull request is ready to be merged."
      ;;
    *dependabot/go_modules*)
      log "Dependabot is updating a Go module dependency, this pull request is ready to be merged."
      ;;
    *)
      warn "This pull request requires manual intervention."
      ;;
  esac
)

# main lists the pull request notifications for the authenticated user and
# triages each one in turn.
main() {
  # trap will catch all EXIT signals from here forward.
  trap trap_exit EXIT

  # ANSI escape sequences used for text output.
  bold_yellow='\033[1;33m'
  bold_red='\033[1;31m'
  bold='\033[1m'
  reset='\033[m'

  # gh authenticates through `gh auth login` or the GH_TOKEN environment variable.
  gh auth status >/dev/null 2>&1 ||
    die "gh is not authenticated, run 'gh auth login' or set the GH_TOKEN environment variable."

  log "Listing notifications for the authenticated user ..."

  # Filter the notifications endpoint response on subject type to grab pull request notifications.
  pull_request_notifications_json="$(
    gh api --paginate notifications --jq '.[] | select( .subject.type == "PullRequest" )'
  )" || die "Unable to list notifications."

  # Iterate over each pull request notification thread, one compact JSON object per line.
  printf '%s\n' "${pull_request_notifications_json}" | jq -c '.' |
    while read -r notification_thread_json; do
      triage_pull_request_notification "${notification_thread_json}"
    done
}

main "$@"
