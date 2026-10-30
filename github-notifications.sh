#!/bin/sh
#
# Triage GitHub pull request notifications for the authenticated user. The
# notifications for closed pull requests are marked as done, Dependabot pull
# requests whose checks have all passed are squash-merged and their
# notifications marked as done, and every other pull request is reported for
# manual review with its notification left in the inbox.

set -euf

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

# parse_arguments sets dry_run from the command line, rejecting anything else.
parse_arguments() {
  dry_run=false

  for argument in "$@"; do
    case "${argument}" in
      --dry-run) dry_run=true ;;
      *) die "Unknown argument: ${argument}" ;;
    esac
  done
}

# check_requirements verifies the required utilities are installed and that gh
# is authenticated.
check_requirements() {
  for utility in gh jq; do
    command -v "${utility}" >/dev/null 2>&1 ||
      die "The following utility is not available and is required --> ${utility}"
  done

  # gh authenticates through `gh auth login` or the GH_TOKEN environment variable.
  gh auth status >/dev/null 2>&1 ||
    die "gh is not authenticated, run 'gh auth login' or set the GH_TOKEN environment variable."
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

# merge_pull_request squash-merges a pull request, with GitHub refusing the
# merge if the head has moved from the SHA whose checks were validated.
merge_pull_request() (
  pull_request_endpoint="${1:?pull request endpoint is required}"
  head_sha="${2:?head SHA is required}"

  gh api --silent --method PUT "${pull_request_endpoint}/merge" \
    -f merge_method=squash -f sha="${head_sha}"
)

# triage_pull_request_notification acts on the pull request behind a
# notification thread
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

  if printf '%s' "${pull_request_json}" | jq -e '( .state == "closed" )' >/dev/null; then
    if [ "${dry_run}" = true ]; then
      log "Pull request is closed, dry run so leaving the notification in the inbox."
      return
    fi

    log "Pull request is closed, marking the notification as done ..."

    mark_notification_done "${notification_thread_endpoint}" ||
      warn "Unable to mark the notification as done, this notification requires manual intervention."
    return
  fi

  if ! printf '%s' "${pull_request_json}" |
    jq -e --arg login "${dependabot_login}" '.user.login == $login' >/dev/null; then
    warn "This pull request was not opened by Dependabot, it requires manual intervention."
    return
  fi

  log "Dependabot opened this pull request, reviewing the status checks ..."

  head_sha="$(printf '%s' "${pull_request_json}" | jq -r '.head.sha')"
  check_runs_endpoint="${repository_endpoint}/commits/${head_sha}/check-runs"

  if ! check_runs_json="$(gh api --method GET -F per_page=100 "${check_runs_endpoint}")"; then
    warn "Unable to retrieve the status checks, this pull request requires manual intervention."
    return
  fi

  if ! printf '%s' "${check_runs_json}" | validate_checks; then
    warn "Status checks have not all completed successfully, this pull request requires manual intervention."
    return
  fi

  mergeable_state="$(printf '%s' "${pull_request_json}" | jq -r '.mergeable_state')"

  case "${mergeable_state}" in
    clean) ;;
    unknown)
      warn "GitHub has not finished calculating whether the pull request can be merged, run the script again shortly."
      return
      ;;
    *)
      warn "GitHub reports the pull request as '${mergeable_state}' rather than 'clean', this pull request requires manual intervention."
      return
      ;;
  esac

  if [ "${dry_run}" = true ]; then
    log "Dependabot pull request is ready to be merged, dry run so leaving it open."
    return
  fi

  log "Dependabot pull request is ready to be merged, merging ..."

  if ! merge_pull_request "${pull_request_endpoint}" "${head_sha}"; then
    warn "Unable to merge the pull request, this pull request requires manual intervention."
    return
  fi

  log "Pull request has been merged, marking the notification as done ..."

  mark_notification_done "${notification_thread_endpoint}" ||
    warn "Unable to mark the notification as done, this notification requires manual intervention."
)

main() {
  trap trap_exit EXIT

  bold_yellow='\033[1;33m'
  bold_red='\033[1;31m'
  bold='\033[1m'
  reset='\033[m'

  # The login GitHub assigns to the Dependabot app when it opens pull requests.
  dependabot_login='dependabot[bot]'

  parse_arguments "$@"
  check_requirements

  if [ "${dry_run}" = true ]; then
    log "Dry run, no pull requests will be merged and no notifications will be marked as done."
  fi

  log "Listing notifications for the authenticated user ..."

  pull_request_notifications_json="$(
    gh api --paginate notifications --jq '.[] | select( .subject.type == "PullRequest" )'
  )" || die "Unable to list notifications."

  printf '%s\n' "${pull_request_notifications_json}" | jq -c '.' |
    while read -r notification_thread_json; do
      triage_pull_request_notification "${notification_thread_json}"
    done
}

main "$@"
