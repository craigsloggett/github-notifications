#!/bin/sh
#
# Triage GitHub pull request notifications for the authenticated user.

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
  for utility in gh jq git terraform-docs go govulncheck; do
    command -v "${utility}" >/dev/null 2>&1 ||
      die "The following utility is not available and is required --> ${utility}"
  done

  gh auth status >/dev/null 2>&1 ||
    die "gh is not authenticated, run 'gh auth login' or set the GH_TOKEN environment variable."
}

# check_runs_state prints whether the check runs on the head commit of a pull
# request are pending, successful, or failed, treating no check runs as
# successful.
check_runs_state() (
  pull_request_json="${1:?pull request JSON is required}"

  repository_endpoint="$(printf '%s' "${pull_request_json}" | jq -r '.base.repo.url')"
  head_sha="$(printf '%s' "${pull_request_json}" | jq -r '.head.sha')"

  gh api --method GET -F per_page=100 "${repository_endpoint}/commits/${head_sha}/check-runs" --jq '
    if any( .check_runs[]; .status != "completed" ) then "pending"
    elif all( .check_runs[]; .conclusion == "success" ) then "success"
    else "failure"
    end
  '
)

# repository_has_file succeeds when a file exists on the default branch of a
# repository.
repository_has_file() (
  repository_endpoint="${1:?repository endpoint is required}"
  file="${2:?file is required}"

  gh api "${repository_endpoint}/contents/${file}" >/dev/null 2>&1
)

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

# merge_clean_pull_request squash-merges a pull request whose check runs have
# all passed, succeeding only once GitHub has merged it.
merge_clean_pull_request() (
  pull_request_json="${1:?pull request JSON is required}"

  mergeable_state="$(printf '%s' "${pull_request_json}" | jq -r '.mergeable_state')"

  case "${mergeable_state}" in
    clean) ;;
    unknown)
      warn "GitHub has not finished calculating whether the pull request can be merged, run the script again shortly."
      return 1
      ;;
    dirty)
      warn "Pull request has merge conflicts, this pull request requires manual intervention."
      return 1
      ;;
    blocked)
      warn "Pull request is blocked by the branch rules of the base repository, this pull request requires manual intervention."
      return 1
      ;;
    *)
      warn "GitHub reports the pull request as '${mergeable_state}' rather than 'clean', this pull request requires manual intervention."
      return 1
      ;;
  esac

  if [ "${dry_run}" = true ]; then
    log "Pull request is ready to be merged, dry run so leaving it open."
    return 1
  fi

  log "Pull request is ready to be merged, merging ..."

  pull_request_endpoint="$(printf '%s' "${pull_request_json}" | jq -r '.url')"
  head_sha="$(printf '%s' "${pull_request_json}" | jq -r '.head.sha')"

  if ! merge_pull_request "${pull_request_endpoint}" "${head_sha}"; then
    warn "Unable to merge the pull request, this pull request requires manual intervention."
    return 1
  fi
)

# request_dependabot_rebase asks Dependabot to rebase a pull request by
# commenting on it.
request_dependabot_rebase() (
  comments_endpoint="${1:?comments endpoint is required}"

  if ! gh api --silent --method POST "${comments_endpoint}" -f body='@dependabot rebase'; then
    warn "Unable to ask Dependabot to rebase, this pull request requires manual intervention."
    return
  fi

  log "Asked Dependabot to rebase, run the script again once the status checks finish."
)

# fix_terraform_docs regenerates README.md with terraform-docs on the head
# branch of a pull request and pushes the resulting commit, failing when
# README.md was already current.
fix_terraform_docs() (
  repository_full_name="${1:?repository full name is required}"
  head_ref="${2:?head ref is required}"

  clone_dir="$(mktemp -d)"
  readonly clone_dir
  trap 'rm -rf "${clone_dir}"' EXIT INT TERM HUP

  gh repo clone "${repository_full_name}" "${clone_dir}" -- --quiet --depth 1 --branch "${head_ref}" || return
  terraform-docs "${clone_dir}" >/dev/null || return

  [ -n "$(git -C "${clone_dir}" status --porcelain)" ] || return 1

  git -C "${clone_dir}" commit --quiet --all --message 'docs: Regenerate README.md with terraform-docs' &&
    git -C "${clone_dir}" push --quiet
)

# scan_govulncheck prints the lowest fixed version of every module with a
# reachable govulncheck finding on a branch of a repository, as module@version
# lines followed by the IDs of the findings the version resolves, with the go
# module standing in for the standard library.
scan_govulncheck() (
  repository_full_name="${1:?repository full name is required}"
  ref="${2:?ref is required}"

  clone_dir="$(mktemp -d)"
  readonly clone_dir
  trap 'rm -rf "${clone_dir}"' EXIT INT TERM HUP

  gh repo clone "${repository_full_name}" "${clone_dir}" -- --quiet --depth 1 --branch "${ref}" || return

  go_mod_json="$(go -C "${clone_dir}" mod edit -json)" || return
  go_version="$(printf '%s' "${go_mod_json}" | jq -r '.Go')"

  findings_json="$(GOTOOLCHAIN="go${go_version}" govulncheck -C "${clone_dir}" -json ./...)" || return

  reachable_findings_json="$(
    printf '%s' "${findings_json}" |
      jq -s 'map( .finding | select( . and .trace[0].function and .fixed_version != "" ) )'
  )"

  highest_fixes_json="$(
    printf '%s' "${reachable_findings_json}" | jq '
      def version_key: ltrimstr("v") | split("-") | .[0] |= ( split(".") | map( tonumber? // 0 ) );
      group_by( .trace[0].module ) | map( {
        module: .[0].trace[0].module,
        fixed_version: ( max_by( .fixed_version | version_key ) | .fixed_version ),
        osvs: ( map( .osv ) | unique )
      } )
    '
  )"

  printf '%s' "${highest_fixes_json}" |
    jq -r '.[] | "\(.module)@\(.fixed_version) \(.osvs | join(" "))" | sub( "^stdlib@v"; "go@" )'
)

# unsatisfied_fixes prints the fixes, given as lines starting with
# module@version, that the go.mod on a ref of a repository does not satisfy with
# a version at or above the fix, with the go directive standing in for the go
# module.
unsatisfied_fixes() (
  repository_endpoint="${1:?repository endpoint is required}"
  ref="${2:?ref is required}"
  fixes="${3:?fixes are required}"

  go_mod_file="$(mktemp)"
  readonly go_mod_file
  trap 'rm -f "${go_mod_file}"' EXIT INT TERM HUP

  gh api --method GET -f ref="${ref}" -H 'Accept: application/vnd.github.raw+json' \
    "${repository_endpoint}/contents/go.mod" >"${go_mod_file}" || return
  go_mod_json="$(go mod edit -json "${go_mod_file}")" || return

  modules_json="$(
    printf '%s' "${go_mod_json}" |
      jq '[ { Path: "go", Version: .Go } ] + ( .Require // [] )'
  )"

  printf '%s\n' "${fixes}" | jq -R -r --argjson modules "${modules_json}" '
    def version_key: ltrimstr("v") | split("-") | .[0] |= ( split(".") | map( tonumber? // 0 ) );
    select( . != "" ) | ( split(" ")[0] | split("@") ) as [ $path, $version ] |
    select(
      any( $modules[]; .Path == $path and ( .Version | version_key ) >= ( $version | version_key ) ) | not
    )
  '
)

# find_fix_pull_request prints the first open pull request in the repository of
# a pull request whose go.mod satisfies any of the fixes, given as
# module@version lines, printing nothing when there is none.
find_fix_pull_request() (
  pull_request_json="${1:?pull request JSON is required}"
  fixes="${2:?fixes are required}"

  repository_endpoint="$(printf '%s' "${pull_request_json}" | jq -r '.base.repo.url')"
  pull_request_endpoint="$(printf '%s' "${pull_request_json}" | jq -r '.url')"

  open_pull_requests_json="$(gh api --method GET -F per_page=100 -f state=open "${repository_endpoint}/pulls")" || return

  printf '%s' "${open_pull_requests_json}" | jq -c --arg url "${pull_request_endpoint}" '.[] | select( .url != $url )' |
    while read -r candidate_json; do
      head_sha="$(printf '%s' "${candidate_json}" | jq -r '.head.sha')"
      candidate_fixes="$(unsatisfied_fixes "${repository_endpoint}" "${head_sha}" "${fixes}")" || continue

      if [ "${candidate_fixes}" != "${fixes}" ]; then
        printf '%s\n' "${candidate_json}"
        break
      fi
    done
)

# open_govulncheck_fix bumps the modules on the base branch of a repository to
# the fixes, given as lines starting with module@version followed by the IDs of
# the findings they resolve, and opens a pull request with the resulting commit.
open_govulncheck_fix() (
  repository_full_name="${1:?repository full name is required}"
  base_ref="${2:?base ref is required}"
  fixes="${3:?fixes are required}"

  clone_dir="$(mktemp -d)"
  readonly clone_dir
  trap 'rm -rf "${clone_dir}"' EXIT INT TERM HUP

  gh repo clone "${repository_full_name}" "${clone_dir}" -- --quiet --depth 1 --branch "${base_ref}" || return

  cd "${clone_dir}" || return

  description="$(
    printf '%s\n' "${fixes}" | jq -R -r '
      select( . != "" ) | split(" ") | ( .[0] | split("@") ) as [ $module, $version ] |
      "- Bumping `\($module)` to `\($version)` to resolve " + ( .[1:] | map( "`\(.)`" ) | join(", ") )
    '
  )"

  printf '%s\n' "${fixes}" | cut -d ' ' -f 1 | xargs -n1 go get &&
    go mod tidy &&
    git switch --quiet --create "${govulncheck_fix_branch}" &&
    git commit --quiet --all --message 'fix: Bump Go and dependencies to patch govulncheck findings' --message "${description}" &&
    git push --quiet --set-upstream origin "${govulncheck_fix_branch}" &&
    gh pr create --fill --base "${base_ref}" --head "${govulncheck_fix_branch}"
)

# merge_fix_pull_request squash-merges the govulncheck fix pull request once
# every check run on its head commit has passed, succeeding only once GitHub has
# merged it.
merge_fix_pull_request() (
  fix_pull_request_endpoint="${1:?fix pull request endpoint is required}"

  if ! fix_pull_request_json="$(gh api "${fix_pull_request_endpoint}")"; then
    warn "Unable to retrieve the fix pull request, this pull request requires manual intervention."
    return 1
  fi

  if ! fix_checks_state="$(check_runs_state "${fix_pull_request_json}")"; then
    warn "Unable to retrieve the fix pull request status checks, this pull request requires manual intervention."
    return 1
  fi

  case "${fix_checks_state}" in
    pending)
      warn "Fix pull request status checks are still running, run the script again shortly."
      return 1
      ;;
    failure)
      warn "Fix pull request status checks failed, the fix pull request requires manual intervention."
      return 1
      ;;
  esac

  merge_clean_pull_request "${fix_pull_request_json}"
)

# settle_fix_pull_request merges an open pull request that has the fix when
# this script opened it and its checks pass, then asks Dependabot to rebase, and
# otherwise waits for it to be merged by hand.
settle_fix_pull_request() (
  fix_pull_request_json="${1:?fix pull request JSON is required}"
  comments_endpoint="${2:?comments endpoint is required}"

  fix_pull_request_number="$(printf '%s' "${fix_pull_request_json}" | jq -r '.number')"
  fix_pull_request_endpoint="$(printf '%s' "${fix_pull_request_json}" | jq -r '.url')"

  if ! printf '%s' "${fix_pull_request_json}" |
    jq -e --arg branch "${govulncheck_fix_branch}" '.head.ref == $branch' >/dev/null; then
    log "Pull request #${fix_pull_request_number} has the fix but was not opened by this script, waiting for it to be merged."
    return
  fi

  log "Pull request #${fix_pull_request_number} has the fix and was opened by this script, reviewing its status checks ..."

  merge_fix_pull_request "${fix_pull_request_endpoint}" || return 0

  log "Fix pull request has been merged, asking Dependabot to rebase ..."

  request_dependabot_rebase "${comments_endpoint}"
)

# repair_govulncheck_findings resolves the reachable govulncheck findings on the
# head branch of a Dependabot pull request.
repair_govulncheck_findings() (
  pull_request_json="${1:?pull request JSON is required}"

  repository_endpoint="$(printf '%s' "${pull_request_json}" | jq -r '.base.repo.url')"
  head_repository_full_name="$(printf '%s' "${pull_request_json}" | jq -r '.head.repo.full_name')"
  head_ref="$(printf '%s' "${pull_request_json}" | jq -r '.head.ref')"
  base_repository_full_name="$(printf '%s' "${pull_request_json}" | jq -r '.base.repo.full_name')"
  base_ref="$(printf '%s' "${pull_request_json}" | jq -r '.base.ref')"
  comments_endpoint="$(printf '%s' "${pull_request_json}" | jq -r '.comments_url')"

  if [ "${dry_run}" = true ]; then
    log "Status checks failed, dry run so not scanning the head branch with govulncheck."
    return
  fi

  log "Status checks failed, scanning the head branch with govulncheck ..."

  if ! fixes="$(scan_govulncheck "${head_repository_full_name}" "${head_ref}")"; then
    warn "Unable to scan the head branch with govulncheck, this pull request requires manual intervention."
    return
  fi

  if [ -z "${fixes}" ]; then
    warn "Head branch has no reachable govulncheck findings, this pull request requires manual intervention."
    return
  fi

  if ! remaining_fixes="$(unsatisfied_fixes "${repository_endpoint}" "${base_ref}" "${fixes}")"; then
    warn "Unable to read go.mod on the base branch, this pull request requires manual intervention."
    return
  fi

  if [ -z "${remaining_fixes}" ]; then
    log "Base branch already has the fix, asking Dependabot to rebase ..."
    request_dependabot_rebase "${comments_endpoint}"
    return
  fi

  if ! fix_pull_request_json="$(find_fix_pull_request "${pull_request_json}" "${remaining_fixes}")"; then
    warn "Unable to list the open pull requests, this pull request requires manual intervention."
    return
  fi

  if [ -n "${fix_pull_request_json}" ]; then
    settle_fix_pull_request "${fix_pull_request_json}" "${comments_endpoint}"
    return
  fi

  log "No open pull request has the fix, opening one ..."

  if ! open_govulncheck_fix "${base_repository_full_name}" "${base_ref}" "${remaining_fixes}"; then
    warn "Unable to open a pull request with the fix, this pull request requires manual intervention."
    return
  fi

  log "Opened a pull request with the fix, run the script again once its status checks finish."
)

# repair_dependabot_pull_request attempts the fixes the repository of a
# Dependabot pull request calls for when its checks fail.
repair_dependabot_pull_request() (
  pull_request_json="${1:?pull request JSON is required}"

  repository_endpoint="$(printf '%s' "${pull_request_json}" | jq -r '.base.repo.url')"
  head_repository_full_name="$(printf '%s' "${pull_request_json}" | jq -r '.head.repo.full_name')"
  head_ref="$(printf '%s' "${pull_request_json}" | jq -r '.head.ref')"

  if repository_has_file "${repository_endpoint}" '.terraform-docs.yml'; then
    if [ "${dry_run}" = true ]; then
      log "Status checks failed, dry run so leaving README.md as is."
      return
    fi

    log "Status checks failed, regenerating README.md with terraform-docs ..."

    if fix_terraform_docs "${head_repository_full_name}" "${head_ref}"; then
      log "Pushed the regenerated README.md, run the script again once the status checks finish."
      return
    fi
  fi

  if repository_has_file "${repository_endpoint}" 'go.mod'; then
    repair_govulncheck_findings "${pull_request_json}"
    return
  fi

  warn "Status checks failed and no automatic fix was applied, this pull request requires manual intervention."
)

# triage_pull_request_notification acts on the pull request behind a
# notification thread.
triage_pull_request_notification() (
  notification_thread_json="${1:?notification thread JSON is required}"

  notification_thread_endpoint="$(printf '%s' "${notification_thread_json}" | jq -r '.url')"
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

  mergeable_state="$(printf '%s' "${pull_request_json}" | jq -r '.mergeable_state')"

  case "${mergeable_state}" in
    unknown)
      warn "GitHub has not finished calculating whether the pull request can be merged, run the script again shortly."
      return
      ;;
    dirty)
      log "Pull request has merge conflicts, skipping it until Dependabot rebases it."
      return
      ;;
  esac

  log "Dependabot opened this pull request, reviewing the status checks ..."

  if ! checks_state="$(check_runs_state "${pull_request_json}")"; then
    warn "Unable to retrieve the status checks, this pull request requires manual intervention."
    return
  fi

  case "${checks_state}" in
    pending)
      warn "Status checks are still running, run the script again shortly."
      return
      ;;
    failure)
      repair_dependabot_pull_request "${pull_request_json}"
      return
      ;;
  esac

  merge_clean_pull_request "${pull_request_json}" || return 0

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

  dependabot_login='dependabot[bot]'
  govulncheck_fix_branch='fix/govulncheck-findings'

  parse_arguments "$@"
  check_requirements

  if [ "${dry_run}" = true ]; then
    log "Dry run, no pull requests will be merged or opened, no commits will be pushed, no comments will be posted, and no notifications will be marked as done."
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
