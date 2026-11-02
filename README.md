# github-notifications

Triage GitHub pull request notifications for the authenticated user.

## Usage

```sh
./github-notifications.sh [--dry-run]
```

For each pull request notification, the script:
1. Marks the notification as done when the pull request is closed.
2. Squash-merges the pull request and marks the notification as done when
   Dependabot opened it, every check run on its head commit has succeeded, and
   GitHub reports it as clean to merge.
3. Skips the pull request when Dependabot opened it and it has merge conflicts,
   leaving the notification in the inbox for Dependabot to rebase it.
4. Repairs the pull request when Dependabot opened it and a check run on its
   head commit failed, leaving the notification in the inbox for a later run to
   merge.
5. Reports every other pull request for manual review, leaving the notification
   in the inbox.

A failing Dependabot pull request is repaired by the first of these that
applies:
1. Regenerating `README.md` with `terraform-docs` on the head branch and pushing
   the commit, when the repository has a `.terraform-docs.yml`.
2. Resolving the reachable `govulncheck` findings on the head branch, when the
   repository has a `go.mod`.

For the `govulncheck` findings, any of these that apply will be done:
1. Asking Dependabot to rebase when the base branch already satisfies them.
2. Waiting for an open pull request whose `go.mod` satisfies any of them, or
   squash-merging it once its checks pass and asking Dependabot to rebase when
   this script opened it from `fix/govulncheck-findings`.
3. Opening a pull request from `fix/govulncheck-findings` that bumps the base
   branch to the versions it is missing.

`--dry-run` reports what the script would do without pushing any commit,
opening, commenting on, or merging any pull request, or marking any
notification as done.

## Requirements

- `gh`, authenticated with `gh auth login` or a `GH_TOKEN` environment variable
  that has `repo` scope
- `jq`
- `git`, with push access to the repositories
- `terraform-docs`
- `go`
- `govulncheck`
